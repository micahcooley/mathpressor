# Mathpressor

A deterministic procedural asset engine and container format for the **Glasswing** project, written in 100% Zig. Mathpressor replaces dictionary compression (LZMA, Zstd, zlib) with demoscene-style mathematical synthesis: assets are stored as tiny bytecode programs that *generate* pixels at runtime rather than storing compressed pixel data.

A **26-byte** program expands into a **9,216-pixel** texture — a 354× expansion ratio — with no stored pixel data at all, and the same bits on every CPU architecture.

---

## How It Works

Traditional game compression: `raw pixels → compress → store → decompress → raw pixels`

Mathpressor: `bytecode program → VM synthesis → raw pixels`

For assets that can be represented procedurally (noise textures, cave masks, marble veins, etc.), the bytecode program is orders of magnitude smaller than even the best compressed representation. For assets that can't be represented procedurally, Mathpressor falls back gracefully to gzip or raw storage — whichever is smaller.

### The Four Storage Routes

When you pack a directory, Mathpressor automatically routes each file:

```
                         ┌─────────────────────────────────────┐
                         │         entropy gate (7.5 b/B)       │
                         └──────────────┬──────────────────────┘
                 entropy < 7.5          │           entropy ≥ 7.5
                         │              │                │
                         ▼              │                ▼
              ┌──────────────────┐      │     ┌──────────────────┐
              │  Math search     │      │     │   addBinary()    │
              │  5 000 attempts  │      │     │  STORE guard     │
              └──────┬───────────┘      │     └──┬───────────────┘
                     │                  │         │
         ┌───────────┼───────────┐      │   ┌─────┴──────┐
         ▼           ▼           ▼      │   ▼            ▼
   [MATH_BYTECODE] [MATH_RESIDUAL] [FALLBACK_STREAM]  [STORE]
   exact match    ≥70% match +    gzip wins          gzip inflates:
   tiny program   gzip'd delta                       raw bytes
```

| Route | Type byte | When | Container overhead |
|---|---|---|---|
| `MATH_BYTECODE` | `0x01` | Program found, bit-perfect | ~10–30 bytes per asset |
| `FALLBACK_STREAM` | `0x02` | Structured/text data | gzip compressed block |
| `STORE` | `0x03` | Already compressed / random | raw bytes (guard prevents inflation) |
| `MATH_RESIDUAL` | `0x04` | ≥70% match found | program + gzip'd delta |

All four routes reconstruct to bit-identical original bytes. To the caller, they are invisible.

---

## Hard Constraints

| Constraint | Implementation |
|---|---|
| **100% Zig** | No C, C++, or Python anywhere in the engine or build system. |
| **Zero float in the core loop** | The VM, math generators, and all runtime paths use strict 32/64-bit integer arithmetic. `f64` is used only in the offline translator (Shannon entropy). Verified bit-identical on x86-64 LE, big-endian s390x, and aarch64 — all produce checksum `0x5757ceb1`. |
| **No hidden allocations** | Every asset is synthesized inside its own `std.heap.ArenaAllocator` torn down on return. The pack CLI uses a streaming writer (one file's compressed data in RAM at a time, not the whole archive). |
| **Custom PRNG** | A hand-rolled, frozen `XorShift32` with shift triple (13, 17, 5). Never `std.Random` — the stdlib's internals can change between Zig releases. Zero-seed remapped to `0xDEAD_BEEF`. |
| **Wrapping arithmetic for delta** | Residual delta uses `-% ` / `+% ` wrapping subtraction/addition, keeping reconstruction in-range without any clamping or branching. |

---

## Architecture

```
mathpressor/
├── build.zig               ReleaseFast + strip by default; produces exe + .so
└── src/
    ├── math_gen.zig        Deterministic integer generators (PRNG, noise, cellular, warp)
    ├── vm.zig              Bytecode interpreter + Builder assembler (11 opcodes)
    ├── translator.zig      Opportunistic translator: entropy gate → math search → delta
    ├── container.zig       .math archive format: Builder, StreamingBuilder, Reader
    ├── gip_interface.zig   C-ABI Ghost Interface Protocol boundary
    └── main.zig            CLI entry point (demo, bench, pack, unpack, pack_demo)
```

Build produces two artifacts:
- `zig-out/bin/mathpressor` — standalone CLI / synthesis daemon
- `zig-out/lib/libmathpressor.so` — GIP shared library the Ghost Engine links at runtime

---

## Instruction Set Architecture

All multi-byte operands are **little-endian**, decoded with explicit `std.mem.readInt` calls — never raw pointer casts — so bytecode is fully portable across architectures.

The VM has **4 buffer slots** (indexed 0–3). `OP_INT_NOISE` fills a slot and makes it the *current* buffer. Post-processing ops (`OP_INVERT`, `OP_ADD_CONST`, etc.) act on the current buffer. `OP_BLEND_MULT`, `OP_MIX`, `OP_WARP`, and `OP_COPY` combine slots.

| Opcode | Mnemonic | Payload | Effect |
|--------|----------|---------|--------|
| `0x01` | `SEED` | `u32` | Reseed the PRNG |
| `0x02` | `INT_NOISE` | `u8 dst, u16 w, u16 h, u8 freq` | 4-octave fractal integer noise → slot `dst`; select it |
| `0x03` | `INVERT` | — | `255 − p` on current buffer |
| `0x04` | `ADD_CONST` | `i16` | Saturating brightness offset |
| `0x05` | `BLEND_MULT` | `u8 src` | `cur[i] = cur[i] * src[i] / 255` (multiply mask) |
| `0x06` | `COPY` | `u8 src, u8 dst` | Copy slot `src` → slot `dst` |
| `0x07` | `CELLULAR` | `u8 steps, u8 birth, u8 survive` | Moore-neighbourhood CA smoothing |
| `0x08` | `WARP` | `u8 src, u8 strength` | Domain-warp current buffer using slot `src` as displacement |
| `0x09` | `LEVEL` | `u8 lo, u8 hi` | Contrast stretch: remap `[lo, hi]` → `[0, 255]` |
| `0x0A` | `THRESHOLD` | `u8 pivot` | Binarise: `≥pivot → 255`, `<pivot → 0` |
| `0x0B` | `MIX` | `u8 src, u8 alpha` | Linear blend current ← `alpha/255 * src` |
| `0xFF` | `HALT` | — | Lock current buffer as output, end execution |

---

## The .math Container Format

Wire layout (all integers little-endian):

```
[12 B]          Header: "MATH" magic, version u16=1, fat_count u32, reserved u16
[280 B × N]     FAT: one entry per file (path[240], comp_type, offsets, sizes, checksum)
[variable]      Data region: compressed blocks in FAT order
```

FAT entry layout (280 bytes):

```
path[240]           null-terminated UTF-8 relative path
comp_type u8        0x01 / 0x02 / 0x03 / 0x04  (see table above)
_pad[7]
data_offset u64     byte offset from start of data region
original_size u64   uncompressed byte count
compressed_size u64 size of stored block (total, including framing)
checksum u32        FNV-1a of original uncompressed bytes
_pad2[4]
```

### MATH_RESIDUAL block layout (inside data region)

```
[u8: bytecode_len]
[bytecode_len bytes: the approximate program]
[u64 le: gz_delta_len]
[gz_delta_len bytes: gzip-compressed residual delta]
```

Reconstruction: `vm_execute(bytecode)[i] +% delta[i] == original[i]` — always exact, wrapping arithmetic, no clamping.

---

## The Translator

`src/translator.zig` runs offline (at pack time) to decide the route for each asset.

**Phase 1 — Entropy gate** (`O(n)`, instant):  
Compute Shannon entropy. If ≥ 7.5 bits/byte (encrypted, already-compressed, random) → immediately route to `addBinary()`. No search.

**Phase 2 — Iterative math search** (up to 5,000 iterations):  
Sweep `(seed, template, frequency)` combinations through the VM. For each candidate, compute the **L1 norm** (sum of per-byte absolute differences).

- L1 = 0 → exact match → `MATH_BYTECODE`
- L1 > 0 but ≥70% of bytes are exact → `MATH_RESIDUAL`
  - Delta compiled as: `delta[i] = raw[i] −% approx[i]`
  - Delta gzip-compressed (exact positions are 0, compresses well)
- Nothing qualifies → `addBinary()` (gzip vs STORE guard)

**The STORE guard** (inside `addBinary`):  
Always compare gzip output size vs raw. If `gz.len ≥ raw.len`, store raw bytes instead — the container never inflates any file.

Built-in templates: `single_noise`, `noise_invert`, `noise_bright`, `blend_mult`, `cave`, `marble`.

---

## The GIP Boundary

The Ghost Engine loads `libmathpressor.so` and drives synthesis through one C-ABI function:

```zig
pub export fn gip_synthesize_asset(
    asset_id: u32,
    bytecode_ptr: [*]const u8,
    bytecode_len: usize,
    out_buffer_ptr: [*]u8,
    out_buffer_len: usize,
) i32;
```

Returns bytes written (≥ 0) or a negative `GIP_ERR_*` code. Each call constructs and destroys its own `ArenaAllocator` over `page_allocator` — no retained state, no hidden heap growth.

---

## Build & Run

```sh
zig build                          # ReleaseFast, stripped — produces exe + .so
zig build test                     # run all 45 unit tests
zig build run                      # synthesis demo (96×96 ASCII preview)

# Modes
./mathpressor                      # demo: synthesise and preview a texture
./mathpressor bench                # benchmark: 5 asset types × 512×512
./mathpressor pack_demo            # showcase: all 4 routes, verify bit-perfect
./mathpressor pack  <dir> <out>    # pack a directory tree → .math archive
./mathpressor unpack <in> <dir>    # unpack a .math archive → directory
./mathpressor <prog.mpc> <out.pgm> # synthesise a .mpc bytecode file → PGM image
```

### Steam folder real-world test

```sh
./mathpressor pack Steam/ steam.math
```

On a real Steam installation (~8.6 GB, 58 000+ files): the streaming builder keeps peak RAM under 15 MB regardless of archive size. Files are routed by entropy — compiled DLLs and `.so` files get gzip'd at 2.4–2.5×, shell scripts and HTML at 3–9×, already-compressed `.tar.xz` / `.gz` files hit the STORE guard and are kept raw.

---

## Determinism Proof

Cross-compiled to big-endian s390x and ran under QEMU. All three architectures (x86-64 LE, s390x BE, aarch64 LE) produce FNV-1a checksum **`0x5757ceb1`** for the same 26-byte program.

The key invariant: all multi-byte operands in the ISA are decoded with `std.mem.readInt(..., .little)` — never via raw pointer casts that would be affected by host endianness.

---

## Test Suite

45 tests across all modules, run with `zig build test`:

| Module | Tests |
|--------|-------|
| `translator.zig` | L1 norm, qualifies-for-approx, entropy, applyDelta, exact match, approx match (dirty 16×16 + 25% corruption), fallback, isCandidate |
| `math_gen.zig` | XorShift32 frozen sequence, zero-seed remap, value noise determinism, fractal noise, warp, level remap, cellular automaton |
| `vm.zig` | All 11 opcodes, determinism across calls, error paths (missing HALT, bad opcode, truncation, slot range, dimension mismatch) |
| `container.zig` | math/fallback round-trips, mixed entries, bad magic rejection, STORE guard (gzip wins / guard fires / never inflates), MATH_RESIDUAL round-trip |
| `main.zig` | GIP integration, pack_demo all five benchmark programs, gzip helper |

---

## File Map

| File | Lines | Role |
|------|-------|------|
| `src/math_gen.zig` | ~340 | Integer PRNG, lattice noise, domain warp, level remap, cellular automata |
| `src/vm.zig` | ~400 | Bytecode interpreter, 11-opcode ISA, Builder assembler |
| `src/translator.zig` | ~380 | Entropy gate, iterative math search, L1 tracking, delta compilation |
| `src/container.zig` | ~700 | `.math` format: in-memory Builder, streaming StreamingBuilder, Reader, 4 extraction paths |
| `src/gip_interface.zig` | ~60 | C-ABI export, per-call arena, error codes |
| `src/main.zig` | ~580 | CLI modes, benchmark, pack demo, recursive directory walker |
| `examples/*.mpc` | 6 files | Pre-built example programs (26–40 bytes each) |
