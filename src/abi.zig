//! abi.zig — Mathpressor C-ABI boundary.
//!
//! Mathpressor is a synthesis engine, not a GUI. This file is the C-ABI surface
//! that host applications link against — the standalone CLI, the bundled GUI, or
//! any program that embeds `libmathpressor.so`. Everything crossing this boundary
//! is plain integers and raw pointers — no Zig types leak out — so a host can
//! call it from C, C++, Rust, or any FFI.
//!
//! All exported symbols use the `mp_` prefix.
//!
//! Memory contract: the caller owns both the input bytecode buffer and the
//! output pixel buffer. Internally each call spins up a private
//! `ArenaAllocator`, does all scratch allocation inside it, and tears it down
//! on return. No allocations outlive the call; nothing is hidden.

const std = @import("std");
const vm = @import("vm.zig");

// ---------------------------------------------------------------------------
// ABI status codes (returned in the i32). >= 0 means success and carries the
// number of bytes written; < 0 is an error code.
// ---------------------------------------------------------------------------

pub const MP_ERR_TRUNCATED: i32 = -1; // bytecode empty or ended mid-instruction
pub const MP_ERR_INVALID_OPCODE: i32 = -2; // unknown opcode byte
pub const MP_ERR_OUT_TOO_SMALL: i32 = -3; // output buffer can't hold the asset
pub const MP_ERR_NO_OUTPUT: i32 = -4; // program never hit OP_HALT
pub const MP_ERR_DIM_MISMATCH: i32 = -5; // conflicting canvas sizes
pub const MP_ERR_SLOT_RANGE: i32 = -6; // slot index out of range
pub const MP_ERR_UNINIT: i32 = -7; // op needed a buffer that didn't exist
pub const MP_ERR_BAD_DIMS: i32 = -8; // zero/oversized dimensions
pub const MP_ERR_OOM: i32 = -9; // arena allocation failed
pub const MP_ERR_NULL: i32 = -10; // null pointer / zero-length argument

fn mapError(e: vm.VmError) i32 {
    return switch (e) {
        error.UnexpectedEnd => MP_ERR_TRUNCATED,
        error.InvalidOpcode => MP_ERR_INVALID_OPCODE,
        error.NoOutput => MP_ERR_NO_OUTPUT,
        error.DimensionMismatch => MP_ERR_DIM_MISMATCH,
        error.SlotOutOfRange => MP_ERR_SLOT_RANGE,
        error.CanvasUninitialized => MP_ERR_UNINIT,
        error.InvalidDimensions => MP_ERR_BAD_DIMS,
        error.OutOfMemory => MP_ERR_OOM,
    };
}

// ---------------------------------------------------------------------------
// The exported entry point.
// ---------------------------------------------------------------------------

/// Synthesize a single asset from its bytecode into `out_buffer`.
///
/// Parameters:
///   asset_id       — opaque key the host uses for caching/logging.
///   bytecode_ptr   — pointer to the Mathpressor program.
///   bytecode_len   — its length in bytes.
///   out_buffer_ptr — destination pixel buffer owned by the caller.
///   out_buffer_len — its capacity in bytes.
///
/// Returns the number of bytes written (>= 0) on success, or a negative
/// MP_ERR_* code on failure.
pub export fn mp_synthesize_asset(
    asset_id: u32,
    bytecode_ptr: [*]const u8,
    bytecode_len: usize,
    out_buffer_ptr: [*]u8,
    out_buffer_len: usize,
) i32 {
    _ = asset_id; // reserved for caching/telemetry on the engine side

    if (bytecode_len == 0) return MP_ERR_TRUNCATED;
    if (out_buffer_len == 0) return MP_ERR_NULL;

    // Per-asset arena over the OS page allocator. `defer deinit` guarantees every
    // scratch byte is reclaimed no matter which path we return through.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const code = bytecode_ptr[0..bytecode_len];
    var machine = vm.Vm.init(arena.allocator());
    const pixels = machine.execute(code) catch |e| return mapError(e);

    if (pixels.len > out_buffer_len) return MP_ERR_OUT_TOO_SMALL;

    const out = out_buffer_ptr[0..out_buffer_len];
    @memcpy(out[0..pixels.len], pixels);
    return @intCast(pixels.len);
}

// ---------------------------------------------------------------------------
// mp_fnv1a — compute FNV-1a checksum over an arbitrary byte range.
//
// Used by the Rust GUI to verify checksums without duplicating the algorithm.
// Returns the 32-bit FNV-1a hash as a u32 written into `out_checksum`.
// Returns 0 on success, MP_ERR_NULL if any pointer is null/zero-length.
// ---------------------------------------------------------------------------

const container = @import("container.zig");

pub export fn mp_fnv1a(
    data_ptr: [*]const u8,
    data_len: usize,
    out_checksum: *u32,
) i32 {
    if (data_len == 0) return MP_ERR_NULL;
    out_checksum.* = container.fnv1a(data_ptr[0..data_len]);
    return 0;
}

// ---------------------------------------------------------------------------
// mp_extract_file — extract one file from an in-memory .math archive.
//
// Parameters:
//   archive_ptr   — pointer to the full .math file bytes in memory.
//   archive_len   — its length.
//   path_ptr      — null-terminated UTF-8 relative path string.
//   out_buffer_ptr — destination buffer owned by the caller.
//   out_buffer_len — its capacity.
//
// Returns the number of bytes written (>= 0) on success, or a negative
// MP_ERR_* code on failure.
//
// This is the primary hook the Rust GUI uses for:
//   (a) "Verify FNV-1a Checksum" — extract then call mp_fnv1a
//   (b) "View Opcodes" — extract raw bytecode for a MATH_BYTECODE entry
// ---------------------------------------------------------------------------

pub export fn mp_extract_file(
    archive_ptr: [*]const u8,
    archive_len: usize,
    path_ptr:    [*:0]const u8,
    out_buffer_ptr: [*]u8,
    out_buffer_len: usize,
) i32 {
    if (archive_len == 0 or out_buffer_len == 0) return MP_ERR_NULL;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const archive = archive_ptr[0..archive_len];
    const path = std.mem.sliceTo(path_ptr, 0);

    var rdr = container.Reader.parse(archive, a) catch return MP_ERR_TRUNCATED;
    defer rdr.deinit();

    const bytes = rdr.extract(path, a) catch |err| {
        return switch (err) {
            error.FileNotFound      => -20,
            error.TruncatedContainer => MP_ERR_TRUNCATED,
            error.SizeMismatch      => -21,
            error.SolidIndexOutOfRange => -22,
            else                    => MP_ERR_TRUNCATED,
        };
    };

    if (bytes.len > out_buffer_len) return MP_ERR_OUT_TOO_SMALL;
    @memcpy(out_buffer_ptr[0..bytes.len], bytes);
    return @intCast(bytes.len);
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn buildValid(a: std.mem.Allocator, w: u16, h: u16) !std.ArrayList(u8) {
    var b = vm.Builder.init(a);
    errdefer b.deinit();
    try b.seed(0xBEEF);
    try b.intNoise(0, w, h, 4);
    try b.halt();
    return b.list;
}

test "mp_synthesize_asset succeeds and reports byte count" {
    var prog = try buildValid(testing.allocator, 16, 16);
    defer prog.deinit();

    var out: [16 * 16]u8 = undefined;
    const rc = mp_synthesize_asset(1, prog.items.ptr, prog.items.len, &out, out.len);
    try testing.expectEqual(@as(i32, 16 * 16), rc);
}

test "mp_synthesize_asset is deterministic across calls" {
    var prog = try buildValid(testing.allocator, 24, 24);
    defer prog.deinit();

    var a: [24 * 24]u8 = undefined;
    var b: [24 * 24]u8 = undefined;
    _ = mp_synthesize_asset(1, prog.items.ptr, prog.items.len, &a, a.len);
    _ = mp_synthesize_asset(2, prog.items.ptr, prog.items.len, &b, b.len);
    try testing.expectEqualSlices(u8, &a, &b);
}

test "mp_synthesize_asset rejects an undersized output buffer" {
    var prog = try buildValid(testing.allocator, 32, 32);
    defer prog.deinit();

    var tiny: [10]u8 = undefined;
    const rc = mp_synthesize_asset(1, prog.items.ptr, prog.items.len, &tiny, tiny.len);
    try testing.expectEqual(MP_ERR_OUT_TOO_SMALL, rc);
}

test "mp_synthesize_asset maps VM errors to status codes" {
    var out: [4]u8 = undefined;

    // Empty bytecode.
    try testing.expectEqual(MP_ERR_TRUNCATED, mp_synthesize_asset(1, &[_]u8{}, 0, &out, out.len));
    // Bad opcode.
    {
        const code = [_]u8{0x00};
        try testing.expectEqual(MP_ERR_INVALID_OPCODE, mp_synthesize_asset(1, &code, code.len, &out, out.len));
    }
    // Truncated seed payload.
    {
        const code = [_]u8{ 0x01, 0x00 };
        try testing.expectEqual(MP_ERR_TRUNCATED, mp_synthesize_asset(1, &code, code.len, &out, out.len));
    }
}

// ---------------------------------------------------------------------------
// mp_verify_archive — verify every entry's FNV-1a against its stored checksum.
//
// Runs entirely in-engine with a single-solid-block cache, so a large solid
// archive verifies in one linear pass. Writes the entry count and the number
// that failed through the out pointers. Returns 0 if verification ran,
// MP_ERR_* (< 0) if the archive could not be opened/parsed.
// ---------------------------------------------------------------------------

pub export fn mp_verify_archive(
    path_ptr: [*:0]const u8,
    out_total: *u32,
    out_failed: *u32,
) i32 {
    const math_main = @import("main.zig");
    const path = std.mem.sliceTo(path_ptr, 0);
    math_main.verifyArchiveAbi(std.heap.page_allocator, path, out_total, out_failed) catch |err| {
        std.debug.print("mp_verify_archive error: {s}\n", .{@errorName(err)});
        return MP_ERR_TRUNCATED;
    };
    return 0;
}

// ---------------------------------------------------------------------------
// Pack via the C-ABI — shared signature for all three modes
// ---------------------------------------------------------------------------

// `effort_tier`: 0=Fast, 1=Balanced, 2=Max — scales gzip level + math search.

pub export fn mp_pack_directory_auto(
    dir_ptr: [*]const u8, dir_len: usize,
    out_ptr: [*]const u8, out_len: usize,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) i32 {
    const math_main = @import("main.zig");
    math_main.packDirectoryAutoAbi(
        std.heap.page_allocator,
        dir_ptr[0..dir_len], out_ptr[0..out_len], effort_tier,
        cancel_flag, progress_ptr, ticker_ptr,
    ) catch |err| {
        if (err != error.Cancelled) std.debug.print("Zig packDirectoryAutoAbi error: {s}\n", .{@errorName(err)});
        return -1;
    };
    progress_ptr.store(1.0, .monotonic);
    return 0;
}

pub export fn mp_pack_directory_vfs(
    dir_ptr: [*]const u8, dir_len: usize,
    out_ptr: [*]const u8, out_len: usize,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) i32 {
    const math_main = @import("main.zig");
    math_main.packDirectoryVfsAbi(
        std.heap.page_allocator,
        dir_ptr[0..dir_len], out_ptr[0..out_len], effort_tier,
        cancel_flag, progress_ptr, ticker_ptr,
    ) catch |err| {
        if (err != error.Cancelled) std.debug.print("Zig packDirectoryVfsAbi error: {s}\n", .{@errorName(err)});
        return -1;
    };
    progress_ptr.store(1.0, .monotonic);
    return 0;
}

pub export fn mp_pack_directory_solid(
    dir_ptr: [*]const u8, dir_len: usize,
    out_ptr: [*]const u8, out_len: usize,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) i32 {
    const math_main = @import("main.zig");
    math_main.packDirectorySolidAbi(
        std.heap.page_allocator,
        dir_ptr[0..dir_len], out_ptr[0..out_len], effort_tier,
        cancel_flag, progress_ptr, ticker_ptr,
    ) catch |err| {
        if (err != error.Cancelled) std.debug.print("Zig packDirectorySolidAbi error: {s}\n", .{@errorName(err)});
        return -1;
    };
    progress_ptr.store(1.0, .monotonic);
    return 0;
}

// Pack an explicit selection of files/directories into one archive using the
// live (regular) per-entry path: dedup + trained-dict pre-passes, no solid
// grouping, so every asset stays independently decodable (random access).
pub export fn mp_pack_selection_vfs(
    base_ptr: [*]const u8, base_len: usize,
    sel_ptr: [*]const u8, sel_len: usize,
    out_ptr: [*]const u8, out_len: usize,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) i32 {
    const math_main = @import("main.zig");
    math_main.packSelectionVfsAbi(
        std.heap.page_allocator,
        base_ptr[0..base_len], sel_ptr[0..sel_len], out_ptr[0..out_len], effort_tier,
        cancel_flag, progress_ptr, ticker_ptr,
    ) catch |err| {
        if (err != error.Cancelled) std.debug.print("Zig packSelectionVfsAbi error: {s}\n", .{@errorName(err)});
        return -1;
    };
    progress_ptr.store(1.0, .monotonic);
    return 0;
}

// Pack an explicit selection of files/directories into one archive using
// native solid grouping (fallback/store files bucketed into shared gzip blocks).
pub export fn mp_pack_selection_solid(
    base_ptr: [*]const u8, base_len: usize,
    sel_ptr: [*]const u8, sel_len: usize,
    out_ptr: [*]const u8, out_len: usize,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) i32 {
    const math_main = @import("main.zig");
    math_main.packSelectionSolidAbi(
        std.heap.page_allocator,
        base_ptr[0..base_len], sel_ptr[0..sel_len], out_ptr[0..out_len], effort_tier,
        cancel_flag, progress_ptr, ticker_ptr,
    ) catch |err| {
        if (err != error.Cancelled) std.debug.print("Zig packSelectionSolidAbi error: {s}\n", .{@errorName(err)});
        return -1;
    };
    progress_ptr.store(1.0, .monotonic);
    return 0;
}

// Full mode: build a real .zip of the selection (at `zip_level` 1..9), then
// wrap it in a .math container (mathpressor STOREs the already-compressed zip).
// Unpack expands the inner zip back to the original files.
pub export fn mp_pack_zip_full(
    base_ptr: [*]const u8, base_len: usize,
    sel_ptr: [*]const u8, sel_len: usize,
    out_ptr: [*]const u8, out_len: usize,
    zip_level: u8,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) i32 {
    const math_main = @import("main.zig");
    math_main.packZipFullAbi(
        std.heap.page_allocator,
        base_ptr[0..base_len], sel_ptr[0..sel_len], out_ptr[0..out_len], zip_level, effort_tier,
        cancel_flag, progress_ptr, ticker_ptr,
    ) catch |err| {
        if (err != error.Cancelled) std.debug.print("Zig packZipFullAbi error: {s}\n", .{@errorName(err)});
        return -1;
    };
    progress_ptr.store(1.0, .monotonic);
    return 0;
}

// Full mode, tar flavour: build a solid uncompressed .tar of the selection
// (std.tar, pure Zig), then zstd-compress it into a .math container at the
// effort tier (FLAG_FULL_TAR). Unpack expands the inner tar natively — no
// system `zip`/`unzip` dependency, and the solid stream lets the compressor
// share its dictionary across file boundaries.
pub export fn mp_pack_tar_full(
    base_ptr: [*]const u8, base_len: usize,
    sel_ptr: [*]const u8, sel_len: usize,
    out_ptr: [*]const u8, out_len: usize,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) i32 {
    const math_main = @import("main.zig");
    math_main.packTarFullAbi(
        std.heap.page_allocator,
        base_ptr[0..base_len], sel_ptr[0..sel_len], out_ptr[0..out_len], effort_tier,
        cancel_flag, progress_ptr, ticker_ptr,
    ) catch |err| {
        if (err != error.Cancelled) std.debug.print("Zig packTarFullAbi error: {s}\n", .{@errorName(err)});
        return -1;
    };
    progress_ptr.store(1.0, .monotonic);
    return 0;
}

// Pack an explicit selection of files/directories into one archive.
// `sel` is a newline-separated list of paths relative to `base`.
pub export fn mp_pack_selection(
    base_ptr: [*]const u8, base_len: usize,
    sel_ptr: [*]const u8, sel_len: usize,
    out_ptr: [*]const u8, out_len: usize,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) i32 {
    const math_main = @import("main.zig");
    math_main.packSelectionAbi(
        std.heap.page_allocator,
        base_ptr[0..base_len], sel_ptr[0..sel_len], out_ptr[0..out_len], effort_tier,
        cancel_flag, progress_ptr, ticker_ptr,
    ) catch |err| {
        if (err != error.Cancelled) std.debug.print("Zig packSelectionAbi error: {s}\n", .{@errorName(err)});
        return -1;
    };
    progress_ptr.store(1.0, .monotonic);
    return 0;
}
