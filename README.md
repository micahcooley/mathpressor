# Mathpressor

A deterministic, standalone procedural asset engine and container format, written in 100% Zig. Mathpressor replaces dictionary compression (LZMA, Zstd, zlib) with demoscene-style mathematical synthesis: assets are stored as tiny bytecode programs that *generate* pixels at runtime rather than storing compressed pixel data. It ships as a CLI, a desktop GUI, and a `libmathpressor.so` any host application can embed over a plain C-ABI.

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
| `MATH_BLOCKS` | `0x07` | Pages part-equation, part-data | per-block descriptors + literal stream |
| `MATH_FILTERED` | `0x08` | Reversible transform helps the codec | filter id + compressed filtered stream |
| `MATH_COLUMNAR` | `0x09` | Record array (vertex/float tables) | AoS→SoA transpose + compressed |
| `MATH_IMAGE2D` | `0x0A` | Raw raster (TGA/PGM/PPM) | 2D MED predictor + compressed |
| `MATH_DICT` | `0x0B` | Many similar small files (JSON/strings/shaders) | zstd frame primed with a shared trained dictionary |
| `MATH_AUDIO` | `0x0C` | 16-bit PCM WAV | fixed-order LPC (per-channel sample predictor) + compressed |

All routes reconstruct to bit-identical original bytes. To the caller, they are invisible.

### Cross-file sharing without a solid block (`MATH_DICT`)

Many small similar files (per-language strings, JSON manifests, shader variants)
compress far better when the codec can reference patterns shared *across* files.
A solid block does that but destroys random access, so it is banned from live
mode. A trained **zstd dictionary** gets the same cross-file sharing while
keeping every entry independently decodable: one dictionary is trained per
file-extension group at pack time, shipped **once** per archive, and each entry
is its own dict-primed frame (still random-access, still live).

It is fully guarded so it never costs bytes:

- A file becomes a `MATH_DICT` entry only when its dict-primed frame is smaller
  than the size it would otherwise get from the real backend (the *honesty
  guard* — at Max that baseline is per-entry LZMA, so a smaller LZMA block is
  never traded for a larger dict one).
- A dictionary is kept only when the group's total saving repays the bytes the
  dictionary costs to ship (the *amortization gate*). Several dictionary sizes
  are tried and the best net is kept.
- Files that don't benefit fall through to normal per-file routing.

Set `MATHPRESSOR_NODICT=1` to disable the route (diagnostic / A-B switch).

### Per-channel sample prediction for audio (`MATH_AUDIO`)

16-bit PCM samples are strongly correlated sample-to-sample, but general
compressors only have *byte-level* delta — they can't predict across a 2-byte
sample or per channel. `MATH_AUDIO` deinterleaves a WAV's channels and applies a
fixed-order linear predictor (the FLAC/Shorten family, orders 0–3, best chosen
per file), storing the residual. The WAV header and any post-data chunks stay
verbatim; only the PCM region is predicted; wrapping integer arithmetic makes it
an exact involution. Because the predictor is net-new ground, this beats general
compressors — even *solid* ones — on raw audio while staying per-entry/live
(measured: a 7-file WAV set packed to 11.9 KB vs solid 7z 18.5 KB, solid xz
23.5 KB, per-file xz 25.3 KB). Honesty-guarded like every route.

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
    ├── abi.zig             Mathpressor C-ABI boundary (mp_* exports)
    └── main.zig            CLI entry point (demo, bench, pack, unpack, pack_demo)
```

Build produces two artifacts:
- `zig-out/bin/mathpressor` — standalone CLI (demo, bench, pack, unpack)
- `zig-out/lib/libmathpressor.so` — C-ABI shared library host applications link at runtime

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
| `0x0C` | `CONST_FILL` | `u8 dst, u16 w, u16 h, u8 value` | Fill slot with a constant byte (padding/sparse files) |
| `0x0D` | `RAMP` | `u8 dst, u16 w, u16 h, u8 start, u8 step` | `buf[i] = start + step·i mod 256` (lookup-table ramps) |
| `0x0E` | `REPEAT` | `u8 dst, u16 w, u16 h, u8 plen, plen×u8` | Tile a literal pattern: `buf[i] = pat[i % plen]` |
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
Any byte length qualifies: the canvas is the smallest covering rectangle
(`side = ceil(√len)`), and extraction truncates the padded tail.

**Phase 1 — Structural gate** (`O(1)`):  
Reject empty files and anything beyond the 4096×4096 canvas (≈16.7 MB).

**Phase 2 — Analytical detectors** (`O(n)`, no search):  
One linear scan recognises three structures that occur in real files and
*constructs* the program directly — no iteration:

- `CONST_FILL` — padding / sparse / zeroed files (the modal byte)
- `RAMP` — arithmetic byte sequences (`start + step·i mod 256`, lookup tables)
- `REPEAT` — short-period tiled patterns (repeated structs, stride records)

An exact hit is verified once through the VM and stored as `MATH_BYTECODE`.
These run **before** the entropy gate deliberately: a perfect byte ramp has a
uniform histogram (8.0 bits/byte) and the entropy heuristic would reject it.

**Phase 3 — Entropy gate** (`O(n)`):  
If ≥ 7.5 bits/byte (encrypted, already-compressed, random) → skip the search
(a qualifying analytic approximation is still carried through).

**Phase 4 — Iterative math search** (budget set by the effort tier):  
Sweep `(seed, template, frequency)` combinations through the VM. For each candidate, compute the **L1 norm** (sum of per-byte absolute differences).

- L1 = 0 → exact match → `MATH_BYTECODE`
- L1 > 0 but ≥70% of bytes are exact → `MATH_RESIDUAL`
  - Delta compiled as: `delta[i] = raw[i] −% approx[i]`
  - Delta compressed (exact positions are 0, compresses well)
- Nothing qualifies → `addBinary()` (compress vs STORE guard)

**The STORE guard** (inside `addBinary`):  
Always compare compressed output size vs raw. If it inflates, store raw bytes instead — the container never inflates any file.

**The residual guard** (pack paths):  
A `MATH_RESIDUAL` is stored only when `program + compressed delta` is smaller
than compressing the whole file — the math route must *earn* its place, never
be overhead dressed up as a win.

**Phase 5 — Per-block decomposition** (`MATH_BLOCKS`, fallback files only):  
Files whose *pages* are part-equation, part-data decompose into 4 KB blocks:
each block gets an exact analytic check (constant / ramp / repeat), equation
blocks become 1–3 byte descriptors, and the literal blocks concatenate into
one stream compressed conventionally. The same honesty guard applies — the
decomposition is stored only when it beats whole-file compression. Measured
honestly: LZ codecs already capture constant and repeated pages nearly free,
so this route fires where analytic pages cost LZ real bytes (e.g., files of
distinct lookup-table ramps: 3.5% smaller than zstd on the same data) and
stays silently out of the way everywhere else.

**Phase 6 — Reversible math filters** (`MATH_FILTERED`):  
A filter is a length-preserving, exactly-invertible integer transform applied
*before* the codec — it shrinks nothing itself, it rewrites the bytes so the
LZ/entropy stage finds more redundancy. This is the literal sense of "use math
to make the file cheaper," and it's how `xz` beats plain DEFLATE:

- **delta** (distance 1 / 2 / 4) — `out[i] = in[i] −% in[i−d]`; turns counters,
  gradients, and PCM-style data into runs of small values the codec crushes.
- **x86 BCJ** — rewrites `CALL`/`JMP` rel32 operands to absolute, so the same
  function called from many sites becomes byte-identical and the codec matches
  it. Reversible because the opcode byte is never touched and the 4 operand
  bytes are skipped, so encode and decode walk identical positions.

The pack path tries the viable filters (BCJ is gated by a cheap x86-density
prescreen), compresses each, and keeps the smallest — but only if it beats the
unfiltered representations (honesty guard). On a real 46 MB Steam `.so` the BCJ
filter is **~5% smaller than zstd-19**, bit-perfect; full mode lifts such
executables out of the solid tar into individual `MATH_FILTERED` entries, so
the binary win and the cross-file solid win compose.

Built-in templates: `single_noise`, `noise_invert`, `noise_bright`, `blend_mult`, `cave`, `marble`, plus the three analytic constructors above.

---

## Two modes: live (regular) vs cold (full)

Mathpressor has two packing modes with different *purposes*, not just different
ratios:

- **Regular mode — live-runnable.** Every asset is an independent, randomly
  accessible entry. The design goal is that a host (e.g. a game) loads the
  `.math` and **synthesizes or extracts only the assets it needs, the moment it
  needs them** — a virtual filesystem where a procedural asset effectively
  doesn't exist until it's requested, then is generated on the spot. This is why
  regular mode never uses solid blocks (which would force decompressing a whole
  block to read one file) and why decode/synthesis *latency* matters as much as
  size. `MATH_BYTECODE` entries are the ideal live primitive: near-zero storage
  and no decompression — pure on-demand VM synthesis. Two passes share data
  *across* files without breaking random access: whole-file **dedup** (identical
  files share one blob) and the trained-**dictionary** route (`MATH_DICT`, above)
  for many similar small files. Both keep every entry independently decodable.

- **Full mode — cold archive.** The whole selection becomes one solid tar →
  LZMA(+x86 BCJ), with a math/transform pre-pass. Maximum ratio, but it must be
  fully expanded to use — *not* live-runnable. Always the smaller of the two.

The intended hierarchy: full mode is #1 on ratio; regular mode is #2 (aiming to
beat every general-purpose compressor) while staying live. The two constraints —
"beat everyone on size" and "run live" — are in genuine tension (a stronger but
slower backend helps the first and hurts the second), which is why regular mode
keeps a fast path and treats heavier backends as a ship/cold option.

One workload stays structurally full-mode's: many tiny *near-duplicate* files.
A solid block references the full window across every file with zero per-frame
overhead; a per-entry dictionary captures the shared patterns but still pays a
small per-frame cost, so it closes most of the gap (e.g. 2.4× better than the
old per-file regular mode on such a corpus) without matching solid. That is the
live-vs-cold trade working as intended — random access has a price, and full
mode is the place you choose to stop paying it.

## The C-ABI

A host application loads `libmathpressor.so` and drives the engine through a plain
C-ABI — only integers and raw pointers cross the boundary, so it is callable from
C, C++, Rust, or any FFI. All exported symbols use the `mp_` prefix.

The core runtime entry point is asset synthesis:

```zig
pub export fn mp_synthesize_asset(
    asset_id: u32,
    bytecode_ptr: [*]const u8,
    bytecode_len: usize,
    out_buffer_ptr: [*]u8,
    out_buffer_len: usize,
) i32;
```

Returns bytes written (≥ 0) or a negative `MP_ERR_*` code. Each call constructs and destroys its own `ArenaAllocator` over `page_allocator` — no retained state, no hidden heap growth.

The same library also exposes the tooling entry points used by the bundled desktop GUI (these walk the filesystem and write archives, so they are heavier than the stateless synthesis call above):

| Symbol | Purpose |
|--------|---------|
| `mp_synthesize_asset` | synthesize one asset from bytecode (runtime path) |
| `mp_pack_directory_auto` / `_vfs` / `_solid` | pack a directory into a `.math` archive |
| `mp_extract_file` | extract one file from a `.math` archive |
| `mp_fnv1a` | FNV-1a checksum helper |

The pack functions run **serially**: `std.Thread.Pool` cannot initialize inside a `dlopen`ed shared library (the Zig start code that sets up thread-local storage never runs), so the parallel pack pipeline lives only in the standalone CLI. The GUI calls these from a background thread, so the UI stays responsive.

---

## Build & Run

```sh
zig build                          # ReleaseFast, stripped — produces exe + .so
zig build test                     # run the unit test suite (52 tests)
zig build run                      # synthesis demo (96×96 ASCII preview)

# Modes
./mathpressor                      # demo: synthesise and preview a texture
./mathpressor bench                # benchmark: 5 asset types × 512×512
./mathpressor pack_demo            # showcase: all 4 routes, verify bit-perfect
./mathpressor pack  <dir> <out>    # pack a directory tree → .math archive
./mathpressor packfull <dir> <out> [tier]  # full mode: solid TAR → zstd .math
./mathpressor unpack <in> <dir>    # unpack a .math archive → directory
./mathpressor <prog.mpc> <out.pgm> # synthesise a .mpc bytecode file → PGM image
```

### Full mode (TAR → MATH)

Full mode trades per-file random access for the best ratio on file trees: the
selection is written as one solid uncompressed tar (`std.tar.writer` — pure
Zig, no system tools), then the whole stream is compressed into the `.math`
container at the effort tier (`FLAG_FULL_TAR`). The tar is ordered by
(extension, path) so similar files sit adjacent in the stream, keeping the
`.math` header, FAT checksum, and GUI integration. Unpack detects the flag and
expands the inner tar with `std.tar.pipeToFileSystem`, preserving symlinks and
executable bits.

The full-mode backend is **LZMA/xz** (`liblzma`, the same kind of system C
dependency already used for libzstd), at preset 6 / 6 / 9-extreme by tier —
a stronger entropy model than zstd (range coder + adaptive bit-contexts +
match model). On real Steam binaries this turns the one case that used to lose
to xz into a win: `linux64` (47 MB) packs to **10.84 MB vs 11.31 MB for stock
`tar | xz -9e`** (and 12.81 MB for `tar | zstd -19`). Only `xz -9e --x86` —
xz's own x86 filter, which the user must know to enable — edges it out, by ~2%.

Before the tar is built, a **parallel math pre-pass** runs the translator over
every file: anything expressible as a bit-perfect program (sparse/zeroed files,
byte ramps, tiled patterns — and at Max, procedural noise) is lifted out of the
tar into a `MATH_BYTECODE` entry, and x86 executables are lifted out as
individual BCJ-filtered LZMA entries — so full mode genuinely combines
mathematical synthesis and reversible transforms with solid traditional
compression. A real Chrome profile's 4 MB zeroed metrics file becomes an
**8-byte program** (524,288×). A program is only accepted when it is strictly
smaller than the file — the math route must earn its place. The iterative noise
search runs at Max only; benchmarked across real corpora it matches nothing the
analytic detectors miss, while the detectors are O(n) and effectively free.

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
| `main.zig` | C-ABI integration, pack_demo all five benchmark programs, gzip helper |

---

## File Map

| File | Lines | Role |
|------|-------|------|
| `src/math_gen.zig` | ~340 | Integer PRNG, lattice noise, domain warp, level remap, cellular automata |
| `src/vm.zig` | ~400 | Bytecode interpreter, 11-opcode ISA, Builder assembler |
| `src/translator.zig` | ~380 | Entropy gate, iterative math search, L1 tracking, delta compilation |
| `src/container.zig` | ~700 | `.math` format: in-memory Builder, streaming StreamingBuilder, Reader, 4 extraction paths |
| `src/abi.zig` | ~60 | C-ABI export, per-call arena, error codes |
| `src/main.zig` | ~580 | CLI modes, benchmark, pack demo, recursive directory walker |
| `examples/*.mpc` | 6 files | Pre-built example programs (26–40 bytes each) |
