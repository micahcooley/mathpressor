// src/main.rs — Mathpressor GUI frontend
//
// Phases implemented:
//   1. Zig engine solid extraction — wired through mp_extract_file C-ABI.
//   2. FNV-1a checksum verification — extract file, hash, compare vs archive.
//   3. Opcode disassembler — parse MATH_BYTECODE payloads into ISA listing.
//   4. Post-pack metric overlays
//   5. Auto-Sensing Mode (Hybrid Optimization)
//
// Architecture rules:
//   • Slint AppWindow is single-threaded; all model writes happen on the
//     event-loop thread via invoke_from_event_loop.
//   • All blocking operations (file I/O, CLI spawn, libloading calls) run in
//     background threads and post results back via invoke_from_event_loop.
//   • libloading resolves Zig symbols at runtime — GUI builds without .so.

#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

slint::include_modules!();

use std::{
    cell::{Cell, RefCell},
    env, fs,
    path::{Path, PathBuf},
    rc::Rc,
    sync::{Arc, OnceLock, atomic::{AtomicU64, Ordering}},
    thread,
};
use slint::{Model, ModelRc, SharedString, VecModel};

thread_local! {
    /// Keeps the progress-poll timer alive for the duration of a pack operation.
    static PACK_TIMER: RefCell<Option<slint::Timer>> = const { RefCell::new(None) };
}

static CACHED_LIB_PATH: OnceLock<Option<PathBuf>> = OnceLock::new();
static SCAN_GENERATION: AtomicU64 = AtomicU64::new(0);

// ---------------------------------------------------------------------------
// Runtime C-ABI bridge (libloading — no compile-time link required)
// ---------------------------------------------------------------------------

use libloading::{Library, Symbol};

/// Locate libmathpressor.so relative to the executable or in standard paths.
fn find_libmathpressor() -> Option<PathBuf> {
    CACHED_LIB_PATH.get_or_init(|| {
        let candidates = [
            std::env::current_exe()
                .ok()
                .and_then(|p| p.parent().map(|d| d.join("libmathpressor.so")))
                .unwrap_or_default(),
            // Zig default output path when called with `zig build -Dlib`
            PathBuf::from("zig-out/lib/libmathpressor.so"),
            PathBuf::from("libmathpressor.so"),
            PathBuf::from("/usr/local/lib/libmathpressor.so"),
        ];
        candidates.into_iter().find(|p| p.exists())
    }).clone()
}

/// Call mp_fnv1a from libmathpressor.so. Falls back to the Rust implementation
/// if the library is not present (so the GUI always works).
fn mp_fnv1a_runtime(data: &[u8]) -> u32 {
    if let Some(path) = find_libmathpressor() {
        if let Ok(lib) = unsafe { Library::new(&path) } {
            type Fn = unsafe extern "C" fn(*const u8, usize, *mut u32) -> i32;
            if let Ok(f) = unsafe { lib.get::<Symbol<Fn>>(b"mp_fnv1a\0") } {
                let mut csum: u32 = 0;
                let rc = unsafe { f(data.as_ptr(), data.len(), &mut csum) };
                if rc == 0 { return csum; }
            }
        }
    }
    // Rust fallback: identical FNV-1a implementation.
    fnv1a_rust(data)
}

/// Call mp_extract_file from libmathpressor.so.
/// Returns the extracted bytes or an error string.
fn mp_extract_file_runtime(archive: &[u8], path: &str) -> Result<Vec<u8>, String> {
    let lib_path = find_libmathpressor()
        .ok_or_else(|| "libmathpressor.so not found — build the Zig engine first".to_string())?;

    let lib = unsafe { Library::new(&lib_path) }
        .map_err(|e| format!("Could not load library: {e}"))?;

    type ExtractFn = unsafe extern "C" fn(
        *const u8, usize, *const u8, *mut u8, usize,
    ) -> i32;

    let func: Symbol<ExtractFn> = unsafe { lib.get(b"mp_extract_file\0") }
        .map_err(|e| format!("mp_extract_file symbol missing: {e}"))?;

    // Use a null-terminated path.
    let mut path_c = path.as_bytes().to_vec();
    path_c.push(0);

    // The FAT records the exact uncompressed size of every entry — math entries
    // expand far past the archive size, so a heuristic cap is not safe here.
    let cap = parse_fat_metrics_bytes(archive)
        .and_then(|fat| fat.get(path).map(|m| m.orig_size as usize))
        .unwrap_or_else(|| archive.len().max(1024 * 1024 * 32))
        .max(1);
    let mut out = vec![0u8; cap];
    let rc = unsafe {
        func(
            archive.as_ptr(), archive.len(),
            path_c.as_ptr(),
            out.as_mut_ptr(), out.len(),
        )
    };

    if rc < 0 {
        return Err(match rc {
            -1  => "Truncated container".to_string(),
            -3  => "Output buffer too small".to_string(),
            -10 => "Null argument".to_string(),
            -20 => format!("File not found in archive: {path}"),
            -21 => "Size mismatch during extraction".to_string(),
            -22 => "Solid block index out of range".to_string(),
            _   => format!("Extraction error code {rc}"),
        });
    }

    out.truncate(rc as usize);
    Ok(out)
}

/// Verify a whole archive in-engine via mp_verify_archive. Returns
/// (total, failed). One linear pass with a solid-block cache on the Zig side —
/// far faster than extracting every entry from Rust and reloading the .so.
fn mp_verify_archive_runtime(archive_path: &Path) -> Result<(u32, u32), String> {
    let lib_path = find_libmathpressor()
        .ok_or_else(|| "libmathpressor.so not found — build the Zig engine first".to_string())?;
    let lib = unsafe { Library::new(&lib_path) }
        .map_err(|e| format!("Could not load library: {e}"))?;
    type VerifyFn = unsafe extern "C" fn(*const u8, *mut u32, *mut u32) -> i32;
    let func: Symbol<VerifyFn> = unsafe { lib.get(b"mp_verify_archive\0") }
        .map_err(|e| format!("mp_verify_archive symbol missing: {e}"))?;

    let mut path_c = archive_path.to_string_lossy().into_owned().into_bytes();
    path_c.push(0);
    let (mut total, mut failed): (u32, u32) = (0, 0);
    let rc = unsafe { func(path_c.as_ptr(), &mut total, &mut failed) };
    if rc < 0 {
        return Err(format!("Could not read or parse archive (code {rc})"));
    }
    Ok((total, failed))
}

// ---------------------------------------------------------------------------
// Pure-Rust FNV-1a (fallback when libmathpressor.so is absent)
// ---------------------------------------------------------------------------

fn fnv1a_rust(data: &[u8]) -> u32 {
    let mut h: u32 = 0x811C_9DC5;
    for &b in data {
        h ^= b as u32;
        h = h.wrapping_mul(0x0100_0193);
    }
    h
}

// ---------------------------------------------------------------------------
// Opcode disassembler (Rust-native — mirrors vm.zig ISA exactly)
// ---------------------------------------------------------------------------

/// Disassemble a MATH_BYTECODE payload into a human-readable listing.
/// Returns a formatted multi-line string ready for the opcode-text panel.
pub fn disassemble(bytecode: &[u8]) -> String {
    let mut out = String::with_capacity(bytecode.len() * 20);
    let mut ip = 0usize;
    let mut line = 0u32;

    macro_rules! read_u8 {
        () => {{
            if ip >= bytecode.len() {
                out.push_str("  !! TRUNCATED — expected u8 operand\n");
                return out;
            }
            let v = bytecode[ip]; ip += 1; v
        }};
    }
    macro_rules! read_u16_le {
        () => {{
            if ip + 2 > bytecode.len() {
                out.push_str("  !! TRUNCATED — expected u16 operand\n");
                return out;
            }
            let v = u16::from_le_bytes([bytecode[ip], bytecode[ip+1]]); ip += 2; v
        }};
    }
    macro_rules! read_i16_le {
        () => {{
            if ip + 2 > bytecode.len() {
                out.push_str("  !! TRUNCATED — expected i16 operand\n");
                return out;
            }
            let v = i16::from_le_bytes([bytecode[ip], bytecode[ip+1]]); ip += 2; v
        }};
    }
    macro_rules! read_u32_le {
        () => {{
            if ip + 4 > bytecode.len() {
                out.push_str("  !! TRUNCATED — expected u32 operand\n");
                return out;
            }
            let v = u32::from_le_bytes([bytecode[ip], bytecode[ip+1], bytecode[ip+2], bytecode[ip+3]]);
            ip += 4; v
        }};
    }

    out.push_str(&format!(
        ";;  Mathpressor Blueprint Disassembly\n\
         ;;  {} bytes\n\
         ;; ─────────────────────────────────────\n",
        bytecode.len()
    ));

    while ip < bytecode.len() {
        let opcode_byte = bytecode[ip]; ip += 1;
        let addr = ip - 1;

        let instr = match opcode_byte {
            0x01 => {
                let seed = read_u32_le!();
                format!("{addr:04X}  SEED         0x{seed:08X}")
            }
            0x02 => {
                let dst  = read_u8!();
                let w    = read_u16_le!();
                let h    = read_u16_le!();
                let freq = read_u8!();
                format!("{addr:04X}  INT_NOISE    dst=s{dst}  {w}×{h}  freq={freq}")
            }
            0x03 => {
                format!("{addr:04X}  INVERT")
            }
            0x04 => {
                let v = read_i16_le!();
                format!("{addr:04X}  ADD_CONST    {v:+}")
            }
            0x05 => {
                let src = read_u8!();
                format!("{addr:04X}  BLEND_MULT   src=s{src}")
            }
            0x06 => {
                let src = read_u8!();
                let dst = read_u8!();
                format!("{addr:04X}  COPY         s{src} → s{dst}")
            }
            0x07 => {
                let steps   = read_u8!();
                let birth   = read_u8!();
                let survive = read_u8!();
                format!("{addr:04X}  CELLULAR     steps={steps}  birth={birth}  survive={survive}")
            }
            0x08 => {
                let src      = read_u8!();
                let strength = read_u8!();
                format!("{addr:04X}  WARP         disp=s{src}  str={strength}")
            }
            0x09 => {
                let lo = read_u8!();
                let hi = read_u8!();
                format!("{addr:04X}  LEVEL        [{lo}, {hi}] → [0, 255]")
            }
            0x0A => {
                let pivot = read_u8!();
                format!("{addr:04X}  THRESHOLD    pivot={pivot}")
            }
            0x0B => {
                let src   = read_u8!();
                let alpha = read_u8!();
                format!("{addr:04X}  MIX          src=s{src}  α={alpha}/255")
            }
            0x0C => {
                let dst = read_u8!();
                let w   = read_u16_le!();
                let h   = read_u16_le!();
                let v   = read_u8!();
                format!("{addr:04X}  CONST_FILL   dst=s{dst}  {w}×{h}  value=0x{v:02X}")
            }
            0x0D => {
                let dst   = read_u8!();
                let w     = read_u16_le!();
                let h     = read_u16_le!();
                let start = read_u8!();
                let step  = read_u8!();
                format!("{addr:04X}  RAMP         dst=s{dst}  {w}×{h}  f(i) = {start} + {step}·i mod 256")
            }
            0x0E => {
                let dst  = read_u8!();
                let w    = read_u16_le!();
                let h    = read_u16_le!();
                let plen = read_u8!() as usize;
                if ip + plen > bytecode.len() {
                    out.push_str("  !! TRUNCATED — expected pattern literal\n");
                    return out;
                }
                let pat: Vec<String> = bytecode[ip..ip+plen].iter().take(16)
                    .map(|b| format!("{b:02X}")).collect();
                ip += plen;
                let ell = if plen > 16 { "…" } else { "" };
                format!("{addr:04X}  REPEAT       dst=s{dst}  {w}×{h}  period={plen}  pat=[{}]{ell}", pat.join(" "))
            }
            0xFF => {
                line += 1;
                out.push_str(&format!("{addr:04X}  HALT\n"));
                out.push_str(&format!(
                    ";; ─────────────────────────────────────\n\
                     ;;  {line} program(s) — {ip} bytes consumed / {} total\n",
                    bytecode.len()
                ));
                break;
            }
            other => {
                format!("{addr:04X}  !! UNKNOWN   0x{other:02X}")
            }
        };

        out.push_str(&instr);
        out.push('\n');
    }

    if ip < bytecode.len() {
        out.push_str(&format!(
            ";; WARNING: {} trailing bytes not decoded\n",
            bytecode.len() - ip
        ));
    }

    out
}

// Context menu action indices mirror appwindow.slint:
//   0 = Compress (Auto)   1 = View Blueprint   2 = Verify Checksum

// ---------------------------------------------------------------------------
// Backend calls (shell out to the Zig CLI binary)
// ---------------------------------------------------------------------------

fn mathpressor_bin() -> PathBuf {
    let mut p = std::env::current_exe()
        .unwrap_or_default()
        .parent()
        .unwrap_or(Path::new("."))
        .join("mathpressor");
    if !p.exists() { p = PathBuf::from("mathpressor"); }
    p
}

// ---------------------------------------------------------------------------
// FFI structures
// ---------------------------------------------------------------------------

// Lock-free status ticker written by Zig, read by the UI timer.
// Using UnsafeCell avoids holding a mutex across the entire ABI call, which
// would block the UI event loop and prevent cancel from working.
use std::cell::UnsafeCell;
struct Ticker(UnsafeCell<[u8; 512]>);
unsafe impl Send for Ticker {}
unsafe impl Sync for Ticker {}
impl Ticker {
    fn new() -> Self { Self(UnsafeCell::new([0u8; 512])) }
    fn as_ptr(&self) -> *mut u8 { self.0.get().cast() }
    fn read_str(&self) -> String {
        let bytes = unsafe { &*self.0.get() };
        let len = bytes.iter().position(|&c| c == 0).unwrap_or(512);
        String::from_utf8_lossy(&bytes[..len]).into_owned()
    }
}

struct PackState {
    cancel_flag: std::sync::atomic::AtomicU8,
    progress:    std::sync::atomic::AtomicU32, // f32 bits
    ticker:      Ticker,
}


/// Short human ETA: "3s", "1m 20s".
fn fmt_eta(secs: f32) -> String {
    let s = secs.max(0.0).round() as u64;
    if s >= 60 { format!("{}m {}s", s / 60, s % 60) } else { format!("{s}s") }
}

/// Shared launcher for every pack operation. Spawns the FFI pack on a background
/// thread; drives the progress bar, current-file ticker, ETA and cancel from the
/// UI thread; then refreshes the route/savings overlays from the finished
/// archive's FAT. `call` performs the actual FFI and returns the ABI rc.
fn run_pack<F>(
    window: &AppWindow,
    out_path: String,
    metrics_base: String,
    busy_label: String,
    call: F,
) where
    F: FnOnce(&PackState) -> Result<i32, String> + Send + 'static,
{
    let handle = window.as_weak();
    let state = Arc::new(PackState {
        cancel_flag: std::sync::atomic::AtomicU8::new(0),
        progress:    std::sync::atomic::AtomicU32::new(0),
        ticker:      Ticker::new(),
    });
    let state_cancel  = Arc::clone(&state);
    let state_pause   = Arc::clone(&state);
    let state_thread  = Arc::clone(&state);
    let state_timer   = Arc::clone(&state);
    let cancel_handle = window.as_weak();
    let pause_handle  = window.as_weak();

    window.on_trigger_cancel(move || {
        state_cancel.cancel_flag.store(1, std::sync::atomic::Ordering::Relaxed);
        if let Some(win) = cancel_handle.upgrade() {
            win.set_cancel_requested(true);
            win.set_status_text(SharedString::from("Cancelling — aborting instantly…"));
        }
    });

    window.on_toggle_pause(move || {
        if let Some(win) = pause_handle.upgrade() {
            let is_paused = win.get_is_paused();
            let new_paused = !is_paused;
            win.set_is_paused(new_paused);
            state_pause.cancel_flag.store(if new_paused { 2 } else { 0 }, std::sync::atomic::Ordering::Relaxed);
            if new_paused {
                win.set_status_text(SharedString::from("Paused."));
            } else {
                win.set_status_text(SharedString::from("Resuming…"));
            }
        }
    });

    // Progress timer: %, current file, and an ETA from elapsed-vs-progress.
    let start = std::time::Instant::now();
    let timer = slint::Timer::default();
    timer.start(slint::TimerMode::Repeated, std::time::Duration::from_millis(80), {
        let handle = handle.clone();
        move || {
            if let Some(win) = handle.upgrade() {
                let p = f32::from_bits(state_timer.progress.load(std::sync::atomic::Ordering::Relaxed));
                win.set_progress_percentage(p);
                win.set_active_file_ticker(SharedString::from(state_timer.ticker.read_str()));
                let eta = if p > 0.02 {
                    let elapsed = start.elapsed().as_secs_f32();
                    format!("about {} left", fmt_eta(elapsed * (1.0 - p) / p))
                } else {
                    "estimating…".to_string()
                };
                win.set_time_remaining(SharedString::from(eta));
            }
        }
    });
    PACK_TIMER.with(|t| *t.borrow_mut() = Some(timer));

    thread::spawn(move || {
        let rc = call(&state_thread);
        let cancelled = state_thread.cancel_flag.load(std::sync::atomic::Ordering::Relaxed) == 1;
        let result: Result<String, String> = match rc {
            Err(e) => Err(e),
            Ok(_) if cancelled => { let _ = fs::remove_file(&out_path); Err("Cancelled.".to_string()) }
            Ok(0)    => Ok(format!("✓ Packed → {out_path}")),
            Ok(code) => Err(format!("✗ Pack failed (ABI code {code})")),
        };

        let parsed = if result.is_ok() { parse_fat_metrics(&out_path) } else { None };
        // Show the actual size win so the user can see what packing achieved.
        let final_text = match result {
            Ok(msg) => match &parsed {
                Some(m) => {
                    let orig: u64 = m.values().map(|v| v.orig_size).sum();
                    let arch = fs::metadata(&out_path).map(|md| md.len()).unwrap_or(0);
                    if orig > 0 && arch > 0 {
                        let pct = (100.0 - (arch as f64 / orig as f64) * 100.0).max(0.0);
                        format!("✓ Packed → {out_path}  ({} → {}, {pct:.1}% smaller)",
                                format_size(orig), format_size(arch))
                    } else {
                        msg
                    }
                }
                None => msg,
            },
            Err(e) => e,
        };

        slint::invoke_from_event_loop(move || {
            PACK_TIMER.with(|t| *t.borrow_mut() = None);
            if let Some(win) = handle.upgrade() {
                if let Some(m) = parsed { apply_metrics_to_entries(&win, &m, &metrics_base); }
                win.set_progress_percentage(0.0);
                win.set_active_file_ticker(SharedString::from(""));
                win.set_time_remaining(SharedString::from(""));
                win.set_status_text(SharedString::from(final_text));
                win.set_cancel_requested(false);
                win.set_is_paused(false);
                win.set_is_processing(false);
                
                // Automatically refresh the view to show the newly created .math file
                win.invoke_trigger_refresh();
            }
        }).ok();
    });

    window.set_cancel_requested(false);
    window.set_is_paused(false);
    window.set_is_processing(true);
    window.set_progress_percentage(0.0);
    window.set_time_remaining(SharedString::from("estimating…"));
    window.set_status_text(SharedString::from(busy_label));
}

/// If `out` already exists, ask the user what to do before packing.
/// Returns the path to write — `out` itself (Replace), an auto-numbered
/// sibling like "name (1).math" (Rename) — or None if the user cancelled.
fn confirm_overwrite(out: &str) -> Option<String> {
    if !Path::new(out).exists() {
        return Some(out.to_string());
    }
    let name = Path::new(out)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| out.to_string());
    let result = rfd::MessageDialog::new()
        .set_level(rfd::MessageLevel::Warning)
        .set_title("Archive already exists")
        .set_description(format!(
            "'{name}' already exists in this folder.\n\n\
             Replace it, save under a new name, or cancel?"
        ))
        .set_buttons(rfd::MessageButtons::YesNoCancelCustom(
            "Replace".to_string(),
            "Rename".to_string(),
            "Cancel".to_string(),
        ))
        .show();

    let rename = || {
        let stem = out.strip_suffix(".math").unwrap_or(out);
        (1..)
            .map(|i| format!("{stem} ({i}).math"))
            .find(|cand| !Path::new(cand).exists())
    };
    match result {
        rfd::MessageDialogResult::Custom(s) if s == "Replace" => Some(out.to_string()),
        rfd::MessageDialogResult::Custom(s) if s == "Rename" => rename(),
        // Some backends report the custom buttons as Yes/No/Cancel.
        rfd::MessageDialogResult::Yes => Some(out.to_string()),
        rfd::MessageDialogResult::No => rename(),
        _ => None,
    }
}

type PackDirFn = unsafe extern "C" fn(
    *const u8, usize, *const u8, usize, u8,
    *const std::sync::atomic::AtomicU8, *const std::sync::atomic::AtomicU32, *mut u8,
) -> i32;

// mp_pack_selection / _solid: the u8 is the effort tier.
type PackSelFn = unsafe extern "C" fn(
    *const u8, usize, *const u8, usize, *const u8, usize, u8,
    *const std::sync::atomic::AtomicU8, *const std::sync::atomic::AtomicU32, *mut u8,
) -> i32;

/// Pack one whole directory (the "Pack Folder" button).
/// Default is smart auto; `solid` selects full mode (solid TAR → MATH).
/// `effort` = mathpressor effort tier (also sets the zstd level over the tar).
fn trigger_pack_file(file_path: &str, out_path: &str, solid: bool, effort: i32, window: &AppWindow) {
    let dir = file_path.trim_end_matches('/').to_owned();
    let out = out_path.to_owned();

    if solid {
        let p = Path::new(&dir);
        if let (Some(parent), Some(name)) = (p.parent(), p.file_name()) {
            trigger_pack_selection(&parent.to_string_lossy(), vec![name.to_string_lossy().into_owned()], out_path, true, effort, window);
            return;
        }
    }

    let (dir_arg, out_arg) = (dir.clone(), out.clone());
    let tier = effort.clamp(0, 2) as u8;
    run_pack(window, out.clone(), dir.clone(), format!("Packing {dir}…"), move |st| {
        let lib_path = find_libmathpressor()
            .ok_or_else(|| "libmathpressor.so not found — build the Zig engine first".to_string())?;
        let lib = unsafe { Library::new(&lib_path) }.map_err(|e| format!("Could not load library: {e}"))?;
        let func: Symbol<PackDirFn> = unsafe { lib.get(b"mp_pack_directory_auto\0") }
            .map_err(|e| format!("symbol missing: {e}"))?;
        Ok(unsafe {
            func(dir_arg.as_ptr(), dir_arg.len(), out_arg.as_ptr(), out_arg.len(), tier,
                 &st.cancel_flag, &st.progress, st.ticker.as_ptr())
        })
    });
}

/// Pack an explicit set of files/folders (relative to `base_dir`) into `out`.
/// When `solid` (full mode), builds a solid tar then mathpresses it with zstd
/// at `effort`; otherwise smart per-file auto routing at `effort`.
fn trigger_pack_selection(base_dir: &str, names: Vec<String>, out: &str, solid: bool, effort: i32, window: &AppWindow) {
    let base = base_dir.trim_end_matches('/').to_owned();
    let out  = out.to_owned();
    let sel  = names.join("\n");
    let n    = names.len();
    let tier = effort.clamp(0, 2) as u8;
    run_pack(window, out.clone(), base.clone(),
        format!("Packing {n} item{}…", if n == 1 { "" } else { "s" }), move |st| {
        let lib_path = find_libmathpressor()
            .ok_or_else(|| "libmathpressor.so not found — build the Zig engine first".to_string())?;
        let lib = unsafe { Library::new(&lib_path) }.map_err(|e| format!("Could not load library: {e}"))?;
        if solid {
            // Full mode: solid tar, zstd'd by the engine at the effort tier.
            let func: Symbol<PackSelFn> = unsafe { lib.get(b"mp_pack_tar_full\0") }
                .map_err(|e| format!("mp_pack_tar_full symbol missing: {e}"))?;
            Ok(unsafe {
                func(base.as_ptr(), base.len(), sel.as_ptr(), sel.len(),
                     out.as_ptr(), out.len(), tier,
                     &st.cancel_flag, &st.progress, st.ticker.as_ptr())
            })
        } else {
            let func: Symbol<PackSelFn> = unsafe { lib.get(b"mp_pack_selection\0") }
                .map_err(|e| format!("mp_pack_selection symbol missing: {e}"))?;
            Ok(unsafe {
                func(base.as_ptr(), base.len(), sel.as_ptr(), sel.len(),
                     out.as_ptr(), out.len(), tier,
                     &st.cancel_flag, &st.progress, st.ticker.as_ptr())
            })
        }
    });
}

// ---------------------------------------------------------------------------
// FAT parser — reads the route tag, sizes and stored checksum for every entry
// in a .math archive.  Returns a map from relative path → FatMeta.
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct FatMeta {
    tag:       &'static str,
    orig_size: u64,
    comp_size: u64,
    checksum:  u32,
}

fn parse_fat_header_and_rows(header: &[u8; 12], fat_buf: &[u8]) -> Option<std::collections::HashMap<String, FatMeta>> {
    if &header[0..4] != b"MATH" { return None; }
    let fat_count = u32::from_le_bytes(header[6..10].try_into().ok()?) as usize;
    if fat_buf.len() < 280 * fat_count { return None; }

    let mut map = std::collections::HashMap::with_capacity(fat_count);
    for i in 0..fat_count {
        let chunk = &fat_buf[i * 280..(i + 1) * 280];
        let path_len = chunk[..240].iter().position(|&c| c == 0).unwrap_or(240);
        let rel_path = String::from_utf8_lossy(&chunk[..path_len]).into_owned();
        let tag = match chunk[240] {
            0x01 => "MATH",
            0x02 => "FALLBACK",
            0x03 => "STORE",
            0x04 => "RESIDUAL",
            0x05 => "SOLID",
            0x06 => "LINK",
            0x07 => "BLOCKS",
            0x08 => "FILTERED",
            0x09 => "COLUMNAR",
            _    => "UNKNOWN",
        };
        // FAT layout: [248..256] data_offset, [256..264] original_size,
        // [264..272] compressed_size, [272..276] FNV-1a checksum
        let orig_size = u64::from_le_bytes(chunk[256..264].try_into().ok()?);
        let comp_size = u64::from_le_bytes(chunk[264..272].try_into().ok()?);
        let checksum  = u32::from_le_bytes(chunk[272..276].try_into().ok()?);
        map.insert(rel_path, FatMeta { tag, orig_size, comp_size, checksum });
    }
    Some(map)
}

/// FLAG_FAT_GZIP (header flags bit 1): the FAT is gzip-compressed with a u64
/// length prefix right after the 12-byte header.
const FLAG_FAT_GZIP: u16 = 0x0002;

fn gunzip(data: &[u8]) -> Option<Vec<u8>> {
    use std::io::Read;
    let mut out = Vec::new();
    flate2::read::GzDecoder::new(data).read_to_end(&mut out).ok()?;
    Some(out)
}

/// Parse the FAT from an archive already loaded in memory.
fn parse_fat_metrics_bytes(archive: &[u8]) -> Option<std::collections::HashMap<String, FatMeta>> {
    if archive.len() < 12 { return None; }
    let header: [u8; 12] = archive[0..12].try_into().ok()?;
    let flags = u16::from_le_bytes(header[10..12].try_into().ok()?);
    let fat_count = u32::from_le_bytes(header[6..10].try_into().ok()?) as usize;

    let raw_fat: Vec<u8> = if flags & FLAG_FAT_GZIP != 0 {
        if archive.len() < 20 { return None; }
        let clen = u64::from_le_bytes(archive[12..20].try_into().ok()?) as usize;
        if archive.len() < 20 + clen { return None; }
        gunzip(&archive[20..20 + clen])?
    } else {
        if archive.len() < 12 + 280 * fat_count { return None; }
        archive[12..12 + 280 * fat_count].to_vec()
    };
    parse_fat_header_and_rows(&header, &raw_fat)
}

/// Parse the FAT directly from a file on disk (reads only header + FAT).
fn parse_fat_metrics(archive_path: &str) -> Option<std::collections::HashMap<String, FatMeta>> {
    use std::io::Read;
    let mut file = std::fs::File::open(archive_path).ok()?;

    let mut header = [0u8; 12];
    file.read_exact(&mut header).ok()?;
    if &header[0..4] != b"MATH" { return None; }
    let flags = u16::from_le_bytes(header[10..12].try_into().ok()?);
    let fat_count = u32::from_le_bytes(header[6..10].try_into().ok()?) as usize;

    let raw_fat: Vec<u8> = if flags & FLAG_FAT_GZIP != 0 {
        let mut len_buf = [0u8; 8];
        file.read_exact(&mut len_buf).ok()?;
        let clen = u64::from_le_bytes(len_buf) as usize;
        let mut comp = vec![0u8; clen];
        file.read_exact(&mut comp).ok()?;
        gunzip(&comp)?
    } else {
        let mut fat_buf = vec![0u8; 280 * fat_count];
        file.read_exact(&mut fat_buf).ok()?;
        fat_buf
    };
    parse_fat_header_and_rows(&header, &raw_fat)
}

// Apply FAT metrics to the file-entry list shown in the explorer.
// FAT paths are relative to `packed_dir`; full_rel_path entries are absolute.
fn apply_metrics_to_entries(
    win: &AppWindow,
    metrics: &std::collections::HashMap<String, FatMeta>,
    packed_dir: &str,
) {
    let base_prefix = format!("{packed_dir}/");
    let model = win.get_file_entries();

    for i in 0..model.row_count() {
        let Some(mut entry) = model.row_data(i) else { continue };
        let abs = entry.full_rel_path.to_string();
        let rel = abs.strip_prefix(&base_prefix).unwrap_or(&abs);
        if let Some(m) = metrics.get(rel) {
            let saved = if m.orig_size > 0 && m.comp_size > 0 && m.comp_size < m.orig_size && m.tag != "STORE" {
                format!("{:.0}%", (1.0 - (m.comp_size as f64 / m.orig_size as f64)) * 100.0)
            } else if m.tag == "STORE" {
                "0%".into()
            } else {
                "—".into()
            };
            entry.route_tag = SharedString::from(m.tag);
            entry.ratio_str = SharedString::from(saved);
            model.set_row_data(i, entry);
        }
    }
}

// ---------------------------------------------------------------------------
// Archive resolution — map a filesystem path to (archive, internal FAT path)
// ---------------------------------------------------------------------------

/// Find the .math archive that contains `file_path` and the relative path the
/// FAT stores it under. The three pack flows place archives differently:
///   • context-menu pack of the file itself  → `<file>.math`, entry = basename
///   • Pack-Folder button on the parent dir  → `<parent>/<parentname>.math`,
///     entry = basename
///   • context-menu pack of the parent dir   → `<parent>.math`,
///     entry = `<parentname>/<basename>`
/// Falls back to scanning sibling .math archives whose FAT contains the file.
fn resolve_archive_for(file_path: &str) -> Option<(PathBuf, String)> {
    let p = Path::new(file_path);
    let parent = p.parent()?;
    let basename = p.file_name()?.to_string_lossy().into_owned();
    let parent_name = parent.file_name().map(|n| n.to_string_lossy().into_owned());

    let mut candidates: Vec<(PathBuf, String)> =
        vec![(PathBuf::from(format!("{file_path}.math")), basename.clone())];
    if let Some(pn) = &parent_name {
        candidates.push((parent.join(format!("{pn}.math")), basename.clone()));
        candidates.push((
            PathBuf::from(format!("{}.math", parent.to_string_lossy())),
            format!("{pn}/{basename}"),
        ));
    }
    for (arc, internal) in &candidates {
        if !arc.exists() { continue; }
        let Some(fat) = arc.to_str().and_then(parse_fat_metrics) else { continue };
        if fat.contains_key(internal) {
            return Some((arc.clone(), internal.clone()));
        }
    }

    // Fallback: any .math archive in the same directory (covers multi-selection
    // packs like "x_and_2_others.math").
    if let Ok(rd) = fs::read_dir(parent) {
        for entry in rd.flatten() {
            let arc = entry.path();
            if arc.extension().map(|e| e == "math") != Some(true) { continue; }
            let Some(fat) = arc.to_str().and_then(parse_fat_metrics) else { continue };
            if fat.contains_key(&basename) {
                return Some((arc, basename.clone()));
            }
            let suffix = format!("/{basename}");
            if let Some(key) = fat.keys().find(|k| k.ends_with(&suffix)) {
                return Some((arc, key.clone()));
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Checksum verification (FNV-1a via mp_extract_file + mp_fnv1a)
// ---------------------------------------------------------------------------

fn verify_checksum_action(file_path: &str, window: &AppWindow) {
    let file_path_owned = file_path.to_owned();
    let handle = window.as_weak();

    window.set_status_text(SharedString::from(
        format!("Verifying checksum for '{}'…", file_path)
    ));
    window.set_is_processing(true);

    thread::spawn(move || {
        let verdict = (|| -> Result<String, String> {
            if file_path_owned.ends_with(".math") {
                // Verify every entry against its stored FNV-1a, in-engine.
                let (total, failed) = mp_verify_archive_runtime(Path::new(&file_path_owned))
                    .map_err(|e| format!("✗ {e}"))?;
                if total == 0 {
                    Ok("✓ Archive is valid but contains no entries".into())
                } else if failed == 0 {
                    Ok(format!("✓ Integrity OK — {total}/{total} checksums match"))
                } else {
                    Err(format!("✗ {failed}/{total} entries FAILED checksum verification"))
                }
            } else {
                // Verify one file against the archive that contains it.
                let (arc_path, internal) = resolve_archive_for(&file_path_owned)
                    .ok_or_else(|| {
                        "✗ No .math archive containing this file was found — pack it first".to_string()
                    })?;
                let archive = fs::read(&arc_path)
                    .map_err(|e| format!("✗ Cannot read archive '{}': {e}", arc_path.display()))?;
                let expected = parse_fat_metrics_bytes(&archive)
                    .and_then(|fat| fat.get(&internal).map(|m| m.checksum))
                    .ok_or_else(|| "✗ Could not read entry checksum from FAT".to_string())?;
                let extracted = mp_extract_file_runtime(&archive, &internal)
                    .map_err(|e| format!("✗ Extraction failed: {e}"))?;
                let computed = mp_fnv1a_runtime(&extracted);
                if computed == expected {
                    Ok(format!(
                        "✓ PASS — FNV-1a 0x{computed:08X} matches {} ({} bytes)",
                        arc_path.file_name().unwrap_or_default().to_string_lossy(),
                        extracted.len()
                    ))
                } else {
                    Err(format!(
                        "✗ MISMATCH — archive says 0x{expected:08X}, extracted data hashes to 0x{computed:08X}"
                    ))
                }
            }
        })().unwrap_or_else(|e| e);

        slint::invoke_from_event_loop(move || {
            if let Some(win) = handle.upgrade() {
                win.set_status_text(SharedString::from(verdict));
                win.set_is_processing(false);
            }
        }).ok();
    });
}

// ---------------------------------------------------------------------------
// Opcode viewer action
// ---------------------------------------------------------------------------

fn view_opcodes_action(file_path: &str, window: &AppWindow) {
    // Resolve which archive to open and which internal path to extract.
    //
    // Case 1: file_path IS a .math archive → show a summary of all MATH entries
    // Case 2: file_path is a regular file  → find the archive that contains it
    //         (covers all three pack flows; see resolve_archive_for)
    // Case 3: nothing found                → show a clear "pack first" message

    let (archive_path_owned, internal_path): (PathBuf, Option<String>) =
        if file_path.ends_with(".math") {
            (PathBuf::from(file_path), None)
        } else {
            match resolve_archive_for(file_path) {
                Some((arc, internal)) => (arc, Some(internal)),
                None => (PathBuf::from(format!("{file_path}.math")), Some(
                    Path::new(file_path).file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default(),
                )),
            }
        };

    let handle = window.as_weak();

    window.set_status_text(SharedString::from(
        format!("Reading blueprint for '{}'…", file_path)
    ));
    window.set_is_processing(true);

    thread::spawn(move || {
        let (panel_title, opcode_text) = (|| {
            if !archive_path_owned.exists() {
                return (
                    "Blueprint Viewer — No Archive".to_string(),
                    format!(
                        "No packed archive found.\n\n\
                         To view a mathematical blueprint:\n\
                         1. Right-click a folder → Compress\n\
                         2. Right-click a file inside the folder → View Mathematical Blueprint\n\n\
                         Looked for: {}",
                        archive_path_owned.display()
                    ),
                );
            }

            let archive = match fs::read(&archive_path_owned) {
                Ok(b) => b,
                Err(e) => return (
                    "Blueprint Viewer — Read Error".to_string(),
                    format!("Cannot read '{}': {e}", archive_path_owned.display()),
                ),
            };

            match internal_path {
                None => {
                    // .math file itself — list all MATH_BYTECODE entries
                    if let Some(metrics) = parse_fat_metrics(
                        archive_path_owned.to_str().unwrap_or("")
                    ) {
                        let math_entries: Vec<_> = metrics.iter()
                            .filter(|(_, m)| m.tag == "MATH")
                            .collect();
                        if math_entries.is_empty() {
                            return ("Blueprint Viewer".to_string(),
                                    "No MATH entries in this archive — all files went through fallback/solid paths.".to_string());
                        }
                        // Disassemble the first MATH entry
                        let (path, _) = &math_entries[0];
                        match mp_extract_file_runtime(&archive, path) {
                            Err(e) => ("Blueprint Viewer — Error".to_string(), e),
                            Ok(bc) => (format!("Blueprint — {path}"), disassemble(&bc)),
                        }
                    } else {
                        ("Blueprint Viewer — Error".to_string(),
                         "Could not parse archive FAT.".to_string())
                    }
                }
                Some(rel) => {
                    match mp_extract_file_runtime(&archive, &rel) {
                        Err(e) => (
                            "Blueprint Viewer — Not Found".to_string(),
                            format!(
                                "'{rel}' not found in archive or not a MATH entry.\n\n\
                                 Note: only files that achieved mathematical synthesis \
                                 (shown as MATH in the Route column) have a blueprint.\n\n\
                                 Error: {e}"
                            ),
                        ),
                        Ok(bc) => (format!("Blueprint — {rel}"), disassemble(&bc)),
                    }
                }
            }
        })();

        slint::invoke_from_event_loop(move || {
            if let Some(win) = handle.upgrade() {
                win.set_opcode_panel_title(SharedString::from(panel_title));
                win.set_opcode_text(SharedString::from(opcode_text));
                win.set_show_opcode_panel(true);
                win.set_is_processing(false);
                win.set_status_text(SharedString::from("Blueprint loaded."));
            }
        }).ok();
    });
}

// ---------------------------------------------------------------------------
// Application state
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct EntryMeta {
    size_bytes: u64,
    modified:   std::time::SystemTime,
}

/// One Explorer tab: a current directory plus its own back/forward history.
#[derive(Clone)]
struct Tab {
    current_dir: PathBuf,
    history:     Vec<PathBuf>,
    history_pos: usize,
    /// User-set tab name (double-click a tab to rename). When set, it overrides
    /// the folder-name title and is kept even as you navigate within the tab.
    custom_title: Option<String>,
}

impl Tab {
    fn new(dir: PathBuf) -> Self {
        Self { current_dir: dir.clone(), history: vec![dir], history_pos: 0, custom_title: None }
    }
    /// Tab-strip title: the user's custom name if set, else the folder name.
    fn title(&self) -> String {
        if let Some(t) = &self.custom_title { return t.clone(); }
        self.current_dir
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| self.current_dir.to_string_lossy().into_owned())
    }
}

/// A pending file operation awaiting a name from the modal dialog.
#[derive(Clone)]
enum PendingOp {
    None,
    NewFolder,
    NewFile,
    Rename(PathBuf), // the file/folder being renamed
    RenameTab(usize), // the tab index being renamed
}

struct AppState {
    tabs:               Vec<Tab>,
    active_tab:         usize,
    // Full (unfiltered) listing of the active tab's dir, plus the search query.
    // The displayed model is `all_entries` filtered by `search_query`.
    all_entries:        Vec<FileEntry>,
    all_meta:           Vec<EntryMeta>,
    search_query:       String,
    context_menu_file:  String,
    sort_mode:          String,
    folders_first:      bool,
    // Copy/cut clipboard: absolute paths + whether this is a move (cut).
    clipboard:          Vec<PathBuf>,
    clipboard_cut:      bool,
    pending_op:         PendingOp,
}

impl AppState {
    fn new(home: PathBuf) -> Self {
        Self {
            tabs:              vec![Tab::new(home)],
            active_tab:        0,
            all_entries:       Vec::new(),
            all_meta:          Vec::new(),
            search_query:      String::new(),
            context_menu_file: String::new(),
            sort_mode:         "Sort: Name (A-Z)".to_string(),
            folders_first:     true,
            clipboard:         Vec::new(),
            clipboard_cut:     false,
            pending_op:        PendingOp::None,
        }
    }
    fn tab(&self) -> &Tab { &self.tabs[self.active_tab] }
    fn tab_mut(&mut self) -> &mut Tab { let i = self.active_tab; &mut self.tabs[i] }
}

fn dirs_home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

// ---------------------------------------------------------------------------
// Directory scanning
// ---------------------------------------------------------------------------

/// Recursively sum the size of all files under `dir`.
fn dir_size(dir: &Path) -> u64 {
    let mut total: u64 = 0;
    if let Ok(rd) = fs::read_dir(dir) {
        for entry in rd.flatten() {
            if let Ok(ft) = entry.file_type() {
                if ft.is_symlink() {
                    // Skip symlinks to avoid infinite recursion from loops
                } else if ft.is_dir() {
                    total += dir_size(&entry.path());
                } else if let Ok(m) = entry.metadata() {
                    total += m.len();
                }
            }
        }
    }
    total
}

fn scan_directory(dir: &Path, sort_mode: &str, folders_first: bool) -> (Vec<FileEntry>, Vec<EntryMeta>) {
    let mut entries: Vec<FileEntry> = Vec::new();
    let mut metas:   Vec<EntryMeta> = Vec::new();

    let Ok(read_dir) = fs::read_dir(dir) else {
        return (entries, metas);
    };

    for result in read_dir {
        let Ok(entry) = result else { continue };
        let meta   = entry.metadata().ok();
        let is_dir = meta.as_ref().map(|m| m.is_dir()).unwrap_or(false);
        let size   = meta.as_ref().map(|m| m.len()).unwrap_or(0);
        let name   = entry.file_name().to_string_lossy().into_owned();
        let full   = entry.path().to_string_lossy().into_owned();

        let modified = meta.as_ref()
            .and_then(|m| m.modified().ok())
            .unwrap_or(std::time::UNIX_EPOCH);

        let mod_str = meta.as_ref()
            .and_then(|m| m.modified().ok())
            .map(|sys_time| {
                let dt: chrono::DateTime<chrono::Local> = sys_time.into();
                dt.format("%b %e, %Y, %I:%M %p").to_string()
            })
            .unwrap_or_else(|| "Unknown".to_string());

        entries.push(FileEntry {
            name:          SharedString::from(&name),
            size_str:      if is_dir { SharedString::from("Calculating…") } else { SharedString::from(format_size(size)) },
            modified_str:  SharedString::from(&mod_str),
            route_tag:     SharedString::from("—"),
            ratio_str:     SharedString::from("—"),
            is_directory:  is_dir,
            full_rel_path: SharedString::from(&full),
            checked:       false,
        });
        metas.push(EntryMeta {
            size_bytes: size,
            modified,
        });
    }

    // Sort entries based on sort_mode, optionally keeping directories on top.
    let mut combined: Vec<_> = entries.into_iter().zip(metas).collect();
    combined.sort_by(|(a, m_a), (b, m_b)| {
        let base_cmp = match sort_mode {
            "Sort: Name (A-Z)"     => a.name.as_str().cmp(b.name.as_str()),
            "Sort: Name (Z-A)"     => b.name.as_str().cmp(a.name.as_str()),
            "Sort: Recent"         => m_b.modified.cmp(&m_a.modified),
            "Sort: Oldest"         => m_a.modified.cmp(&m_b.modified),
            "Sort: Size (Big-Small)"   => m_b.size_bytes.cmp(&m_a.size_bytes),
            "Sort: Size (Small-Big)" => m_a.size_bytes.cmp(&m_b.size_bytes),
            _                      => a.name.as_str().cmp(b.name.as_str()),
        };
        if folders_first {
            b.is_directory.cmp(&a.is_directory).then(base_cmp)
        } else {
            base_cmp
        }
    });

    combined.into_iter().unzip()
}

fn format_size(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;
    match bytes {
        0           => "0 B".into(),
        b if b < KB => format!("{b} B"),
        b if b < MB => format!("{:.1} KB", b as f64 / KB as f64),
        b if b < GB => format!("{:.1} MB", b as f64 / MB as f64),
        b           => format!("{:.2} GB", b as f64 / GB as f64),
    }
}

/// Case-insensitive substring filter of a listing by file name. Empty query
/// returns everything (cloned).
fn filter_entries(entries: &[FileEntry], query: &str) -> Vec<FileEntry> {
    if query.trim().is_empty() {
        return entries.to_vec();
    }
    let q = query.to_lowercase();
    entries.iter()
        .filter(|e| e.name.to_lowercase().contains(&q))
        .cloned()
        .collect()
}

/// After a successful pack, re-scan the directory and attach metric overlays.
/// `packed_files` is a Vec of (rel_path, route_tag, original_size, stored_size).

// ---------------------------------------------------------------------------
// Filesystem operations (new / rename / delete / copy / move)
// ---------------------------------------------------------------------------

/// Recursively copy a file or directory tree to `dst`.
fn copy_recursive(src: &Path, dst: &Path) -> std::io::Result<()> {
    let meta = fs::symlink_metadata(src)?;
    let ft = meta.file_type();
    if ft.is_symlink() {
        let target = fs::read_link(src)?;
        #[cfg(unix)]
        std::os::unix::fs::symlink(&target, dst)?;
        #[cfg(not(unix))]
        fs::copy(src, dst).map(|_| ())?;
        Ok(())
    } else if ft.is_dir() {
        fs::create_dir_all(dst)?;
        for entry in fs::read_dir(src)? {
            let entry = entry?;
            copy_recursive(&entry.path(), &dst.join(entry.file_name()))?;
        }
        Ok(())
    } else {
        if let Some(parent) = dst.parent() { fs::create_dir_all(parent)?; }
        fs::copy(src, dst).map(|_| ())
    }
}

/// Pick a non-colliding destination path in `dir` for `name`, appending
/// " (copy)", " (copy 2)", … if needed.
fn unique_dest(dir: &Path, name: &std::ffi::OsStr) -> PathBuf {
    let first = dir.join(name);
    if !first.exists() { return first; }
    let base = Path::new(name);
    let stem = base.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = base.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    for i in 1.. {
        let suffix = if i == 1 { " (copy)".to_string() } else { format!(" (copy {i})") };
        let cand = dir.join(format!("{stem}{suffix}{ext}"));
        if !cand.exists() { return cand; }
    }
    unreachable!()
}

/// Move src→dst, falling back to copy+delete when rename crosses filesystems.
fn move_path(src: &Path, dst: &Path) -> std::io::Result<()> {
    match fs::rename(src, dst) {
        Ok(()) => Ok(()),
        Err(_) => {
            copy_recursive(src, dst)?;
            if src.is_dir() { fs::remove_dir_all(src) } else { fs::remove_file(src) }
        }
    }
}

// ---------------------------------------------------------------------------
// Entry point + multi-window support
// ---------------------------------------------------------------------------

static WINDOW_SEQ: AtomicU64 = AtomicU64::new(0);

thread_local! {
    /// (id, handle) for every open OS window. Slint frees a window's component
    /// when its last Rust handle drops, so we retain them here. On close we drop
    /// the handle (deferred) and quit the loop once none remain.
    static OPEN_WINDOWS: RefCell<Vec<(u64, AppWindow)>> = const { RefCell::new(Vec::new()) };
}

/// Handle a window close: drop its retained handle (deferred to after the
/// close callback returns, so we never free the component mid-callback) and
/// quit the event loop once the last window is gone.
fn close_window(id: u64) {
    slint::invoke_from_event_loop(move || {
        let empty = OPEN_WINDOWS.with(|v| {
            let mut vec = v.borrow_mut();
            vec.retain(|(wid, _)| *wid != id);
            vec.is_empty()
        });
        if empty { let _ = slint::quit_event_loop(); }
    }).ok();
}

/// Resolve a key + shift state to a 1-based number. Handles both the bare digit
/// and the US-layout shifted symbols (Shift+2 reports "@" on most platforms).
fn digit_of(key: &str, shift: bool) -> Option<usize> {
    if key.len() == 1 {
        let c = key.chars().next().unwrap();
        if c.is_ascii_digit() { return c.to_digit(10).map(|d| d as usize); }
        if shift {
            return match key {
                "!" => Some(1), "@" => Some(2), "#" => Some(3), "$" => Some(4),
                "%" => Some(5), "^" => Some(6), "&" => Some(7), "*" => Some(8), "(" => Some(9),
                _ => None,
            };
        }
    }
    None
}

/// Raise/focus the Nth open OS window (0-based). Prunes closed windows first so
/// the index follows currently-visible windows. On Wayland winit's focus_window
/// is a documented no-op (the compositor forbids programmatic raise); on X11,
/// Windows and macOS it actually brings the window forward.
fn focus_os_window(n: usize) {
    use slint::winit_030::WinitWindowAccessor;
    OPEN_WINDOWS.with(|v| {
        let mut vec = v.borrow_mut();
        vec.retain(|(_, w)| w.window().is_visible());
        if let Some((_, w)) = vec.get(n) {
            w.window().with_winit_window(|ww| {
                ww.set_minimized(false);
                ww.focus_window();
            });
        }
    });
}

/// Recount checked rows and push every selection-related property to the UI,
/// including `all-checked` (true only when *every* row is checked).
fn update_selection_counts(win: &AppWindow) {
    let model = win.get_file_entries();
    let total = model.row_count();
    let (mut count, mut reg, mut math, mut has_math) = (0i32, 0i32, 0i32, false);
    for i in 0..total {
        if let Some(e) = model.row_data(i) {
            if e.checked {
                count += 1;
                if e.name.ends_with(".math") { has_math = true; math += 1; } else { reg += 1; }
            }
        }
    }
    win.set_selected_folder_count(count);
    win.set_selected_regular_count(reg);
    win.set_selected_math_count(math);
    win.set_has_math_selected(has_math);
    win.set_all_checked(total > 0 && count as usize == total);
}

/// Absolute paths of all checked rows (used for multi-select file ops).
fn checked_paths(win: &AppWindow) -> Vec<PathBuf> {
    let model = win.get_file_entries();
    (0..model.row_count())
        .filter_map(|i| model.row_data(i))
        .filter(|e| e.checked)
        .map(|e| PathBuf::from(e.full_rel_path.as_str()))
        .collect()
}

fn main() -> Result<(), slint::PlatformError> {
    let window = build_app_window()?; // registers itself in OPEN_WINDOWS
    window.show()?;
    slint::run_event_loop()?;
    Ok(())
}

/// Build a fully-wired, independent app window (its own tabs/windows/state).
/// Called once at startup and again for every "New OS window". The window
/// registers itself in OPEN_WINDOWS; the caller only needs to show() it.
fn build_app_window() -> Result<AppWindow, slint::PlatformError> {
    let window = AppWindow::new()?;
    let win_id = WINDOW_SEQ.fetch_add(1, Ordering::Relaxed);
    let home   = dirs_home();
    let state  = Rc::new(RefCell::new(AppState::new(home)));

    // ── Render: push the active tab's (filtered) listing + strips to the UI ─
    // Reads state.all_entries and applies the search filter. Called by refresh,
    // search, and the background size thread — never rescans the disk itself.
    let render_view = {
        let state = state.clone();
        let win_weak = window.as_weak();
        move || {
            let Some(win) = win_weak.upgrade() else { return };
            let s = state.borrow();
            let shown = filter_entries(&s.all_entries, &s.search_query);
            win.set_file_entries(ModelRc::new(VecModel::from(shown)));
        }
    };

    // ── Refresh: rescan the active tab's directory, then render ────────────
    let refresh_explorer = {
        let state = state.clone();
        let win_weak = window.as_weak();
        let render = render_view.clone();
        move || {
            let (dir, path_str, can_back, can_fwd, sort_mode, folders_first,
                 tab_titles, active_tab) = {
                let s = state.borrow();
                let t = s.tab();
                (t.current_dir.clone(),
                 t.current_dir.to_string_lossy().into_owned(),
                 t.history_pos > 0,
                 t.history_pos + 1 < t.history.len(),
                 s.sort_mode.clone(),
                 s.folders_first,
                 s.tabs.iter().map(|t| SharedString::from(t.title())).collect::<Vec<_>>(),
                 s.active_tab as i32)
            };

            let (entries, metas) = scan_directory(&dir, &sort_mode, folders_first);

            let dir_indices: Vec<(usize, PathBuf)> = entries.iter().enumerate()
                .filter(|(_, e)| e.is_directory)
                .map(|(i, e)| (i, PathBuf::from(e.full_rel_path.as_str())))
                .collect();

            {
                let mut s = state.borrow_mut();
                s.all_entries = entries.clone();
                s.all_meta    = metas.clone();
            }
            render();

            if let Some(win) = win_weak.upgrade() {
                win.set_current_path(SharedString::from(path_str.clone()));
                win.set_status_text(SharedString::from(format!("  {path_str}")));
                win.set_selected_folder_count(0);
                win.set_can_go_back(can_back);
                win.set_can_go_forward(can_fwd);
                win.set_tab_titles(ModelRc::new(VecModel::from(tab_titles)));
                win.set_active_tab(active_tab);
            }

            // Compute directory sizes off the UI thread, then set the (filtered)
            // model directly. The thread can't touch the Rc state (not Send), so
            // we capture the search query up front and filter by name here — the
            // filter is name-based, so it's unaffected by the computed sizes.
            if !dir_indices.is_empty() {
                let win_weak_bg = win_weak.clone();
                let gen = SCAN_GENERATION.fetch_add(1, Ordering::Relaxed) + 1;
                let mut bg_entries = entries;
                let mut bg_metas = metas;
                let bg_sort_mode = sort_mode.clone();
                let query = { state.borrow().search_query.clone() };

                thread::spawn(move || {
                    let sizes: Vec<(usize, u64)> = dir_indices.into_iter()
                        .map(|(i, path)| (i, dir_size(&path)))
                        .collect();
                    for &(i, size) in &sizes {
                        if i < bg_metas.len() && i < bg_entries.len() {
                            bg_metas[i].size_bytes = size;
                            bg_entries[i].size_str = SharedString::from(format_size(size));
                        }
                    }
                    let mut combined: Vec<_> = bg_entries.into_iter().zip(bg_metas).collect();
                    combined.sort_by(|(a, m_a), (b, m_b)| {
                        b.is_directory.cmp(&a.is_directory).then_with(|| match bg_sort_mode.as_str() {
                            "Sort: Name (A-Z)"       => a.name.as_str().cmp(b.name.as_str()),
                            "Sort: Name (Z-A)"       => b.name.as_str().cmp(a.name.as_str()),
                            "Sort: Recent"           => m_b.modified.cmp(&m_a.modified),
                            "Sort: Oldest"           => m_a.modified.cmp(&m_b.modified),
                            "Sort: Size (Big-Small)" => m_b.size_bytes.cmp(&m_a.size_bytes),
                            "Sort: Size (Small-Big)" => m_a.size_bytes.cmp(&m_b.size_bytes),
                            _                        => a.name.as_str().cmp(b.name.as_str()),
                        })
                    });
                    let (final_entries, _): (Vec<_>, Vec<_>) = combined.into_iter().unzip();
                    let shown = filter_entries(&final_entries, &query);

                    slint::invoke_from_event_loop(move || {
                        if SCAN_GENERATION.load(Ordering::Relaxed) != gen { return; }
                        if let Some(win) = win_weak_bg.upgrade() {
                            win.set_file_entries(ModelRc::new(VecModel::from(shown)));
                        }
                    }).ok();
                });
            }
        }
    };

    // ── Initial scan ───────────────────────────────────────────────────────
    refresh_explorer();

    // Navigate to a new location, recording it in history (truncating any
    // forward entries first — exactly like a browser address bar).
    let go_to = {
        let state = state.clone();
        let refresh = refresh_explorer.clone();
        move |dir: PathBuf| {
            {
                let mut s = state.borrow_mut();
                let t = s.tab_mut();
                if t.current_dir == dir { return; }
                let pos = t.history_pos;
                t.history.truncate(pos + 1);
                t.history.push(dir.clone());
                t.history_pos = t.history.len() - 1;
                t.current_dir = dir;
            }
            refresh();
        }
    };
    let go_back = {
        let state = state.clone();
        let refresh = refresh_explorer.clone();
        move || {
            {
                let mut s = state.borrow_mut();
                let t = s.tab_mut();
                if t.history_pos == 0 { return; }
                t.history_pos -= 1;
                t.current_dir = t.history[t.history_pos].clone();
            }
            refresh();
        }
    };
    let go_forward = {
        let state = state.clone();
        let refresh = refresh_explorer.clone();
        move || {
            {
                let mut s = state.borrow_mut();
                let t = s.tab_mut();
                if t.history_pos + 1 >= t.history.len() { return; }
                t.history_pos += 1;
                t.current_dir = t.history[t.history_pos].clone();
            }
            refresh();
        }
    };

    { let go = go_back.clone();    window.on_navigate_back(move || go()); }
    { let go = go_forward.clone(); window.on_navigate_forward(move || go()); }

    // ── navigate-up ────────────────────────────────────────────────────────
    {
        let state = state.clone();
        let go = go_to.clone();
        window.on_navigate_up(move || {
            let parent = { state.borrow().tab().current_dir.parent().map(PathBuf::from) };
            if let Some(p) = parent { go(p); }
        });
    }

    // ── tabs: select / close / new (within the active window) ──────────────
    {
        let state = state.clone();
        let refresh = refresh_explorer.clone();
        window.on_tab_selected(move |idx| {
            { let mut s = state.borrow_mut(); let i = idx as usize; if i < s.tabs.len() { s.active_tab = i; } }
            refresh();
        });
    }
    {
        let state = state.clone();
        let refresh = refresh_explorer.clone();
        window.on_tab_closed(move |idx| {
            {
                let mut s = state.borrow_mut();
                let i = idx as usize;
                if s.tabs.len() <= 1 || i >= s.tabs.len() { return; }
                s.tabs.remove(i);
                if s.active_tab >= s.tabs.len() { s.active_tab = s.tabs.len() - 1; }
                else if s.active_tab > i { s.active_tab -= 1; }
            }
            refresh();
        });
    }
    {
        let state = state.clone();
        let refresh = refresh_explorer.clone();
        window.on_new_tab(move || {
            {
                let mut s = state.borrow_mut();
                let dir = s.tab().current_dir.clone(); // open new tab at current dir
                s.tabs.push(Tab::new(dir));
                s.active_tab = s.tabs.len() - 1;
            }
            refresh();
        });
    }
    // ── rename a tab (double-click) → seed the name dialog with its title ──
    {
        let state = state.clone();
        let win_weak = window.as_weak();
        window.on_tab_rename_requested(move |idx| {
            let Some(win) = win_weak.upgrade() else { return };
            let i = idx as usize;
            let cur = {
                let s = state.borrow();
                if i >= s.tabs.len() { return; }
                s.tabs[i].title()
            };
            state.borrow_mut().pending_op = PendingOp::RenameTab(i);
            win.set_name_dialog_title(SharedString::from("Rename tab"));
            win.set_name_dialog_text(SharedString::from(cur));
            win.set_show_name_dialog(true);
        });
    }

    // ── keyboard shortcuts ─────────────────────────────────────────────────
    //   Ctrl+W           close tab
    //   Ctrl+1..9        switch tab
    //   Ctrl+Shift+1..9  raise OS window N (real on X11/Win/macOS; no-op on Wayland)
    // (Ctrl+T new tab and Ctrl+N new OS window are handled directly in Slint.)
    {
        let state = state.clone();
        let refresh = refresh_explorer.clone();
        window.on_shortcut(move |key, shift| {
            let key = key.to_string();
            if key == "w" {
                let mut changed = false;
                {
                    let mut s = state.borrow_mut();
                    if s.tabs.len() > 1 {
                        let at = s.active_tab; s.tabs.remove(at);
                        if s.active_tab >= s.tabs.len() { s.active_tab = s.tabs.len() - 1; }
                        changed = true;
                    }
                }
                if changed { refresh(); }
                return;
            }
            if let Some(n) = digit_of(&key, shift) {
                if shift {
                    // Window switch — no state change, just raise the OS window.
                    focus_os_window(n - 1);
                } else {
                    let mut changed = false;
                    {
                        let mut s = state.borrow_mut();
                        if n - 1 < s.tabs.len() { s.active_tab = n - 1; changed = true; }
                    }
                    if changed { refresh(); }
                }
            }
        });
    }

    // ── search: filter the current listing live ────────────────────────────
    {
        let state = state.clone();
        let render = render_view.clone();
        window.on_search_changed(move |q| {
            state.borrow_mut().search_query = q.to_string();
            render();
        });
    }

    // ── refresh ───────────────────────────────────────────────────────────
    {
        let refresh = refresh_explorer.clone();
        window.on_trigger_refresh(move || { refresh(); });
    }

    // ── sort changed ──────────────────────────────────────────────────────
    {
        let state = state.clone();
        let refresh = refresh_explorer.clone();
        window.on_sort_changed(move |new_sort| {
            state.borrow_mut().sort_mode = new_sort.to_string();
            refresh();
        });
    }

    // ── folders first changed ─────────────────────────────────────────────
    {
        let state = state.clone();
        let refresh = refresh_explorer.clone();
        window.on_folders_first_changed(move |checked| {
            state.borrow_mut().folders_first = checked;
            refresh();
        });
    }

    // ── path-changed ───────────────────────────────────────────────────────
    {
        let go = go_to.clone();
        window.on_path_changed(move |new_path| {
            let p = PathBuf::from(new_path.as_str());
            if p.is_dir() { go(p); }
        });
    }

    // ── browse-folder ──────────────────────────────────────────────────────
    {
        let go = go_to.clone();
        window.on_browse_folder(move || {
            if let Some(folder) = rfd::FileDialog::new().pick_folder() { go(folder); }
        });
    }

    // ── double-click (navigate into dir) ──────────────────────────────────
    {
        let go = go_to.clone();
        window.on_file_double_clicked(move |path| {
            let p = PathBuf::from(path.as_str());
            if p.is_dir() { go(p); }
        });
    }

    // ── close opcode panel ─────────────────────────────────────────────────
    {
        let win_weak = window.as_weak();
        window.on_close_opcode_panel(move || {
            if let Some(win) = win_weak.upgrade() {
                win.set_show_opcode_panel(false);
                win.set_opcode_text(SharedString::from(""));
            }
        });
    }

    // ── pack current folder (always auto mode) ────────────────────────────
    {
        let win_weak = window.as_weak();
        window.on_trigger_pack(move || {
            let Some(win) = win_weak.upgrade() else { return };
            let dir = win.get_current_path().to_string();
            let dir_path = Path::new(&dir);
            let name = dir_path.file_name().unwrap_or_default().to_string_lossy();
            let solid = win.get_solid_archive();
            // Full-mode archives are named .tar.math so the mode is visible on disk.
            let ext = if solid { "tar.math" } else { "math" };
            let out_name = if name.is_empty() { format!("Archive.{ext}") } else { format!("{}.{ext}", name) };
            let out_path = dir_path.join(out_name);
            let Some(out) = confirm_overwrite(&out_path.to_string_lossy()) else { return };
            trigger_pack_file(&dir, &out, solid, win.get_effort_tier(), &win);
        });
    }

    // ── pack selected folders ─────────────────────────────────────────────
    {
        let win_weak = window.as_weak();
        window.on_pack_selected(move || {
            let Some(win) = win_weak.upgrade() else { return };
            let model = win.get_file_entries();
            // Every checked item — files and folders — relative to the current dir.
            let names: Vec<String> = (0..model.row_count())
                .filter_map(|i| model.row_data(i))
                .filter(|e| e.checked && !e.name.ends_with(".math"))
                .map(|e| e.name.to_string())
                .collect();
            if names.is_empty() { return; }

            let base = win.get_current_path().to_string();
            let solid = win.get_solid_archive();
            let ext = if solid { "tar.math" } else { "math" };
            let out_name = if names.len() == 1 {
                format!("{}.{ext}", names[0])
            } else {
                format!("{}_and_{}_others.{ext}", names[0], names.len() - 1)
            };
            let out = Path::new(&base).join(out_name).to_string_lossy().to_string();
            let Some(out) = confirm_overwrite(&out) else { return };
            trigger_pack_selection(&base, names, &out, solid, win.get_effort_tier(), &win);
        });
    }

    // ── toggle folder checkbox (single click anywhere on the row) ──────────
    // Also tracks the last-clicked index for shift-click range selection.
    let last_clicked: Rc<Cell<Option<usize>>> = Rc::new(Cell::new(None));
    {
        let win_weak = window.as_weak();
        let last = Rc::clone(&last_clicked);
        window.on_toggle_entry_check(move |idx| {
            let Some(win) = win_weak.upgrade() else { return };
            let i = idx as usize;
            let model = win.get_file_entries();
            if let Some(mut entry) = model.row_data(i) {
                entry.checked = !entry.checked;
                model.set_row_data(i, entry);
            }
            last.set(Some(i));
            update_selection_counts(&win);
        });
    }

    // ── shift-click range selection ──────────────────────────────────────────
    {
        let win_weak = window.as_weak();
        let last = Rc::clone(&last_clicked);
        window.on_shift_click_entry(move |idx| {
            let Some(win) = win_weak.upgrade() else { return };
            let end = idx as usize;
            let start = last.get().unwrap_or(end);
            let lo = start.min(end);
            let hi = start.max(end);
            let model = win.get_file_entries();
            // Check everything in the range
            for i in lo..=hi {
                if let Some(mut entry) = model.row_data(i) {
                    if !entry.checked {
                        entry.checked = true;
                        model.set_row_data(i, entry);
                    }
                }
            }
            update_selection_counts(&win);
            last.set(Some(end));
        });
    }

    // ── select all folders ────────────────────────────────────────────────
    {
        let win_weak = window.as_weak();
        window.on_select_all_folders(move || {
            let Some(win) = win_weak.upgrade() else { return };
            let model = win.get_file_entries();
            for i in 0..model.row_count() {
                if let Some(mut entry) = model.row_data(i) {
                    entry.checked = true;
                    model.set_row_data(i, entry);
                }
            }
            update_selection_counts(&win);
        });
    }

    // ── clear selection ───────────────────────────────────────────────────
    {
        let win_weak = window.as_weak();
        window.on_clear_selection(move || {
            let Some(win) = win_weak.upgrade() else { return };
            let model = win.get_file_entries();
            for i in 0..model.row_count() {
                if let Some(mut entry) = model.row_data(i) {
                    if entry.checked {
                        entry.checked = false;
                        model.set_row_data(i, entry);
                    }
                }
            }
            update_selection_counts(&win);
        });
    }

    // ── unpack archive ─────────────────────────────────────────────────────
    {
        let win_weak = window.as_weak();
        window.on_trigger_unpack(move || {
            let Some(win) = win_weak.upgrade() else { return };
            let model = win.get_file_entries();
            
            // Collect all selected .math files
            let mut arc_paths = Vec::new();
            for i in 0..model.row_count() {
                if let Some(entry) = model.row_data(i) {
                    if entry.checked && entry.name.ends_with(".math") {
                        arc_paths.push(entry.full_rel_path.to_string());
                    }
                }
            }
            if arc_paths.is_empty() { return; }

            // Extract right there (current directory)
            let dest_dir = win.get_current_path().to_string();
            let bin = mathpressor_bin();
            let handle = win.as_weak();
            
            let label = if arc_paths.len() == 1 {
                Path::new(&arc_paths[0]).file_name().unwrap_or_default().to_string_lossy().into_owned()
            } else {
                format!("{} archives", arc_paths.len())
            };
            
            win.set_is_processing(true);
            win.set_status_text(SharedString::from(format!("Unpacking {}…", label)));
            
            thread::spawn(move || {
                let mut all_success = true;
                let mut err_msg = String::new();
                
                for arc_str in arc_paths {
                    let result = std::process::Command::new(&bin)
                        .args(["unpack", &arc_str, &dest_dir])
                        .output();
                        
                    match result {
                        Ok(o) => {
                            if !o.status.success() {
                                all_success = false;
                                err_msg = String::from_utf8_lossy(&o.stderr).into_owned();
                                break;
                            }
                        }
                        Err(e) => {
                            all_success = false;
                            err_msg = format!("{}", e);
                            break;
                        }
                    }
                }
                
                let final_text = if all_success {
                    format!("✓ Unpacked into {}", dest_dir)
                } else {
                    format!("✗ Failed: {}", err_msg)
                };
                
                slint::invoke_from_event_loop(move || {
                    if let Some(w) = handle.upgrade() {
                        w.set_status_text(SharedString::from(final_text));
                        w.set_is_processing(false);
                        w.invoke_trigger_refresh();
                    }
                }).ok();
            });
        });
    }

    // ── test integrity ─────────────────────────────────────────────────────
    {
        let win_weak = window.as_weak();
        window.on_trigger_test_integrity(move || {
            let Some(win) = win_weak.upgrade() else { return };
            let archive = rfd::FileDialog::new()
                .add_filter("Mathpressor Archive", &["math"])
                .pick_file();
            let Some(arc_path) = archive else { return };

            let arc_str = arc_path.to_string_lossy().into_owned();
            let handle  = win.as_weak();
            win.set_is_processing(true);
            win.set_status_text(SharedString::from(format!("Testing integrity of {arc_str}…")));

            thread::spawn(move || {
                let result: String = match fs::read(&arc_str) {
                    Err(e) => format!("✗ Cannot read archive: {e}"),
                    Ok(bytes) => {
                        // Verify the MATH magic header.
                        if bytes.len() < 4 || &bytes[0..4] != b"MATH" {
                            "✗ Not a valid Mathpressor archive (bad magic)".into()
                        } else if bytes.len() < 12 {
                            "✗ Truncated archive header".into()
                        } else {
                            let fat_count = u32::from_le_bytes([bytes[6], bytes[7], bytes[8], bytes[9]]);
                            format!("✓ Valid MATH archive — {fat_count} file(s) in FAT — {} total",
                                    format_size(bytes.len() as u64))
                        }
                    }
                };
                slint::invoke_from_event_loop(move || {
                    if let Some(w) = handle.upgrade() {
                        w.set_status_text(SharedString::from(result));
                        w.set_is_processing(false);
                    }
                }).ok();
            });
        });
    }

    // ── right-click — show in-app context menu at cursor ──────────────────
    {
        let state = state.clone();
        let win_weak = window.as_weak();
        window.on_file_right_clicked(move |path, mx, my| {
            state.borrow_mut().context_menu_file = path.to_string();
            if let Some(win) = win_weak.upgrade() {
                win.set_context_menu_x(mx);
                win.set_context_menu_y(my);
                win.set_is_math_file_context(path.ends_with(".math"));
                win.set_show_context_menu(true);
            }
        });
    }

    // ── context menu action dispatch ──────────────────────────────────────
    {
        let state = state.clone();
        let win_weak = window.as_weak();
        let refresh = refresh_explorer.clone();
        window.on_context_menu_action(move |idx| {
            let Some(win) = win_weak.upgrade() else { return };
            let file_path = state.borrow().context_menu_file.clone();
            match idx {
                // Pack the right-clicked item (file OR folder) into <item>.math.
                // Routing through the selection packer lets a single file pack too.
                0 => {
                    let p = Path::new(&file_path);
                    if let (Some(parent), Some(name)) = (p.parent(), p.file_name()) {
                        let solid = win.get_solid_archive();
                        let ext = if solid { "tar.math" } else { "math" };
                        let out = format!("{}.{ext}", file_path.trim_end_matches('/'));
                        let Some(out) = confirm_overwrite(&out) else { return };
                        trigger_pack_selection(
                            &parent.to_string_lossy(),
                            vec![name.to_string_lossy().into_owned()],
                            &out, solid, win.get_effort_tier(), &win,
                        );
                    }
                }
                1 => view_opcodes_action(&file_path, &win),
                2 => verify_checksum_action(&file_path, &win),
                // 4 = Rename → open the name dialog seeded with the basename.
                4 => {
                    let p = PathBuf::from(&file_path);
                    let cur = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                    state.borrow_mut().pending_op = PendingOp::Rename(p);
                    win.set_name_dialog_title(SharedString::from("Rename"));
                    win.set_name_dialog_text(SharedString::from(cur));
                    win.set_show_name_dialog(true);
                }
                // 5 = Delete → all checked items (or the right-clicked one).
                5 => {
                    let mut targets = checked_paths(&win);
                    if targets.is_empty() { targets.push(PathBuf::from(&file_path)); }
                    let msg = if targets.len() == 1 {
                        let n = targets[0].file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                        format!("Delete '{n}'?\n\nThis cannot be undone.")
                    } else {
                        format!("Delete these {} items?\n\nThis cannot be undone.", targets.len())
                    };
                    let ok = rfd::MessageDialog::new()
                        .set_level(rfd::MessageLevel::Warning)
                        .set_title("Confirm delete")
                        .set_description(msg)
                        .set_buttons(rfd::MessageButtons::OkCancel)
                        .show();
                    if matches!(ok, rfd::MessageDialogResult::Ok | rfd::MessageDialogResult::Yes) {
                        let (mut ok_n, mut last_err) = (0usize, String::new());
                        for p in &targets {
                            let res = if p.is_dir() { fs::remove_dir_all(p) } else { fs::remove_file(p) };
                            match res { Ok(()) => ok_n += 1, Err(e) => last_err = e.to_string() }
                        }
                        win.set_status_text(SharedString::from(if last_err.is_empty() {
                            format!("Deleted {ok_n} item{}", if ok_n == 1 { "" } else { "s" })
                        } else { format!("✗ Delete failed: {last_err}") }));
                        refresh();
                    }
                }
                // 6 = Copy, 7 = Cut → all checked items (or the right-clicked one).
                6 | 7 => {
                    let mut targets = checked_paths(&win);
                    if targets.is_empty() { targets.push(PathBuf::from(&file_path)); }
                    let n = targets.len();
                    {
                        let mut s = state.borrow_mut();
                        s.clipboard = targets;
                        s.clipboard_cut = idx == 7;
                    }
                    win.set_can_paste(true);
                    win.set_status_text(SharedString::from(
                        format!("{} {n} item{}", if idx == 7 { "Cut" } else { "Copied" },
                                if n == 1 { "" } else { "s" })));
                }
                3 => {
                    let arc_str = file_path.clone();
                    let dest_dir = win.get_current_path().to_string();
                    let bin      = mathpressor_bin();
                    let handle   = win.as_weak();
                    win.set_is_processing(true);
                    let label = Path::new(&arc_str).file_name().unwrap_or_default().to_string_lossy();
                    win.set_status_text(SharedString::from(format!("Unpacking {}…", label)));
                    thread::spawn(move || {
                        let result = std::process::Command::new(&bin)
                            .args(["unpack", &arc_str, &dest_dir])
                            .output()
                            .map(|o| {
                                if o.status.success() { format!("✓ Unpacked into {}", dest_dir) }
                                else { format!("✗ {}", String::from_utf8_lossy(&o.stderr)) }
                            })
                            .unwrap_or_else(|e| format!("✗ {e}"));
                        slint::invoke_from_event_loop(move || {
                            if let Some(w) = handle.upgrade() {
                                w.set_status_text(SharedString::from(result));
                                w.set_is_processing(false);
                                w.invoke_trigger_refresh();
                            }
                        }).ok();
                    });
                }
                _ => {}
            }
        });
    }

    // ── Quit (File menu) ───────────────────────────────────────────────────
    window.on_quit(|| { let _ = slint::quit_event_loop(); });

    // ── New Folder / New File → open the name dialog ───────────────────────
    {
        let state = state.clone();
        let win_weak = window.as_weak();
        window.on_new_folder(move || {
            let Some(win) = win_weak.upgrade() else { return };
            state.borrow_mut().pending_op = PendingOp::NewFolder;
            win.set_name_dialog_title(SharedString::from("New folder"));
            win.set_name_dialog_text(SharedString::from("New folder"));
            win.set_show_name_dialog(true);
        });
    }
    {
        let state = state.clone();
        let win_weak = window.as_weak();
        window.on_new_file(move || {
            let Some(win) = win_weak.upgrade() else { return };
            state.borrow_mut().pending_op = PendingOp::NewFile;
            win.set_name_dialog_title(SharedString::from("New file"));
            win.set_name_dialog_text(SharedString::from("untitled.txt"));
            win.set_show_name_dialog(true);
        });
    }

    // ── Name dialog: OK performs the pending operation ─────────────────────
    {
        let state = state.clone();
        let win_weak = window.as_weak();
        let refresh = refresh_explorer.clone();
        window.on_name_dialog_ok(move || {
            let Some(win) = win_weak.upgrade() else { return };
            let raw = win.get_name_dialog_text().to_string();
            win.set_show_name_dialog(false);

            let op = {
                let mut s = state.borrow_mut();
                let op = s.pending_op.clone();
                s.pending_op = PendingOp::None;
                op
            };

            // Tab rename: a free-form label (spaces allowed). Empty resets to
            // the folder name. Doesn't touch the filesystem.
            if let PendingOp::RenameTab(i) = op {
                let label = raw.trim().to_string();
                {
                    let mut s = state.borrow_mut();
                    if i < s.tabs.len() {
                        s.tabs[i].custom_title = if label.is_empty() { None } else { Some(label) };
                    }
                }
                refresh();
                return;
            }

            // File/folder names: stricter — no separators or dot entries.
            let trimmed = raw.trim().trim_matches('/').to_string();
            if trimmed.is_empty() || trimmed.contains('/') || trimmed == "." || trimmed == ".." {
                win.set_status_text(SharedString::from("✗ Invalid name"));
                return;
            }
            let dir = state.borrow().tab().current_dir.clone();
            let result: std::io::Result<String> = match op {
                PendingOp::NewFolder => {
                    let target = dir.join(&trimmed);
                    if target.exists() { Err(std::io::Error::new(std::io::ErrorKind::AlreadyExists, "exists")) }
                    else { fs::create_dir(&target).map(|_| format!("Created folder {trimmed}")) }
                }
                PendingOp::NewFile => {
                    let target = dir.join(&trimmed);
                    if target.exists() { Err(std::io::Error::new(std::io::ErrorKind::AlreadyExists, "exists")) }
                    else { fs::File::create(&target).map(|_| format!("Created {trimmed}")) }
                }
                PendingOp::Rename(old) => {
                    let target = old.parent().map(|p| p.join(&trimmed)).unwrap_or_else(|| PathBuf::from(&trimmed));
                    if target.exists() { Err(std::io::Error::new(std::io::ErrorKind::AlreadyExists, "exists")) }
                    else { fs::rename(&old, &target).map(|_| format!("Renamed to {trimmed}")) }
                }
                _ => return,
            };
            match result {
                Ok(msg) => win.set_status_text(SharedString::from(msg)),
                Err(e) => win.set_status_text(SharedString::from(format!("✗ {e}"))),
            }
            refresh();
        });
    }
    {
        let state = state.clone();
        let win_weak = window.as_weak();
        window.on_name_dialog_cancel(move || {
            state.borrow_mut().pending_op = PendingOp::None;
            if let Some(win) = win_weak.upgrade() { win.set_show_name_dialog(false); }
        });
    }

    // ── Paste: copy (or move, if cut) the clipboard into the active dir ────
    {
        let state = state.clone();
        let win_weak = window.as_weak();
        let refresh = refresh_explorer.clone();
        window.on_paste_items(move || {
            let Some(win) = win_weak.upgrade() else { return };
            let (items, is_cut, dir) = {
                let s = state.borrow();
                (s.clipboard.clone(), s.clipboard_cut, s.tab().current_dir.clone())
            };
            if items.is_empty() { return; }

            let mut ok = 0usize;
            let mut last_err = String::new();
            for src in &items {
                let Some(name) = src.file_name() else { continue };
                let dst = unique_dest(&dir, name);
                let res = if is_cut { move_path(src, &dst) } else { copy_recursive(src, &dst) };
                match res { Ok(()) => ok += 1, Err(e) => last_err = e.to_string() }
            }

            if is_cut {
                // A cut is one-shot: clear the clipboard after moving.
                let mut s = state.borrow_mut();
                s.clipboard.clear();
                s.clipboard_cut = false;
                drop(s);
                win.set_can_paste(false);
            }
            win.set_status_text(SharedString::from(if last_err.is_empty() {
                format!("{} {ok} item{}", if is_cut { "Moved" } else { "Pasted" }, if ok == 1 { "" } else { "s" })
            } else {
                format!("✗ {last_err}")
            }));
            refresh();
        });
    }

    // ── New OS window: spawn a fully independent second window ─────────────
    window.on_new_os_window(|| {
        match build_app_window() {
            Ok(w) => { let _ = w.show(); }   // build_app_window self-registers
            Err(e) => eprintln!("failed to open new window: {e}"),
        }
    });

    // ── Close handling ─────────────────────────────────────────────────────
    // If a pack/compress op is running, confirm first (Pause / Abort / Cancel).
    // Otherwise drop this window's handle and quit once the last one closes.
    {
        let weak = window.as_weak();
        window.window().on_close_requested(move || {
            let processing = weak.upgrade().map(|w| w.get_is_processing()).unwrap_or(false);
            if processing {
                let choice = rfd::MessageDialog::new()
                    .set_level(rfd::MessageLevel::Warning)
                    .set_title("Operation in progress")
                    .set_description("A compression operation is still running in this window.\n\nWhat would you like to do?")
                    .set_buttons(rfd::MessageButtons::YesNoCancelCustom(
                        "Pause and close".to_string(),
                        "Abort and close".to_string(),
                        "Cancel".to_string(),
                    ))
                    .show();
                use rfd::MessageDialogResult as R;
                match choice {
                    // Cancel → keep the window open, op continues.
                    R::Custom(s) if s == "Cancel" => return slint::CloseRequestResponse::KeepWindowShown,
                    R::Cancel => return slint::CloseRequestResponse::KeepWindowShown,
                    // Pause and close → pause the op, then close.
                    R::Custom(s) if s == "Pause and close" => {
                        if let Some(w) = weak.upgrade() { if !w.get_is_paused() { w.invoke_toggle_pause(); } }
                    }
                    R::Yes => {
                        if let Some(w) = weak.upgrade() { if !w.get_is_paused() { w.invoke_toggle_pause(); } }
                    }
                    // Abort and close → cancel the op (removes partial output), then close.
                    _ => {
                        if let Some(w) = weak.upgrade() { w.invoke_trigger_cancel(); }
                    }
                }
            }
            close_window(win_id);
            slint::CloseRequestResponse::HideWindow
        });
    }

    OPEN_WINDOWS.with(|v| v.borrow_mut().push((win_id, window.clone_strong())));
    Ok(window)
}
