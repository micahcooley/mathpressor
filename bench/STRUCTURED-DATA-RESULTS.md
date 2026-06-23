# mathpressor vs zstd/xz on structured data — the formula codecs' home turf

The question this answers: on game/media (authored, opaque) data, mathpressor *loses*
to 7-Zip/xz. Is there a data class where its formula-based codecs (delta filter,
columnar transpose, predictors, residual) *beat* the statistical compressors? Yes —
decisively. Harness: `bench/structured-gen.py` (numpy) + `bench/structured-bench.py`.
All numbers Ryzen 5 5600X, mathpressor **regular/live mode** (so the wins come WITH
random-access/seekable, which zstd/xz frames don't have). All round-trips bit-exact
(`bench/verify-lossless.sh`: LOSSLESS, 8/8).

| dataset (4 MB each) | mathpressor | codec it picked | zstd-19 | zstd-22 | xz-9e | winner |
|---|---|---|---|---|---|---|
| monotonic u32 counter | **9070×** | filtered (delta) | 4.4× | 4.4× | 29× | **MP (308× past xz)** |
| 8-bit gradient image | **21.6×** | filtered (delta) | 14.5× | 14.5× | 15.5× | **MP +40%** |
| 8-bit terrain heightmap | **9.9×** | filtered (delta) | 7.9× | 7.9× | 8.8× | **MP +13%** |
| tabular records (AoS) | **2.72×** | columnar (SoA) | 1.45× | 1.45× | 1.96× | **MP +39%** |
| float32 scientific field | **2.07×** | columnar | 1.11× | 1.11× | 1.30× | **MP +59%** |
| float32 time-series | **1.52×** | columnar | 1.15× | 1.15× | 1.42× | **MP +7%** |
| 16-bit PCM audio | **1.47×** | columnar | 1.00× | 1.00× | 1.03× | **MP +43%** |
| sparse/constant 8-bit | 240× | fallback | 209× | 256× | 281× | xz (only loss) |

**mathpressor wins 7/8, often by huge margins.** This is the exact inverse of the
game-asset result.

## Why — and why it's not luck

Statistical compressors (zstd, xz, 7-Zip) find **repeated substrings** and entropy-code
them. Structured data's redundancy isn't substrings — it's **numerical / predictive**:
- A monotonic counter has *no* repeated substrings, so zstd gets 4.4× and xz 29× — but a
  **delta** turns it into near-zeros → 9070×. That's the signature: a one-line formula
  beats a world-class entropy coder by 300×.
- Smooth fields/images: neighbouring values are *close*, not *equal* — a **predictor/delta**
  captures that; substring matching can't.
- Tabular/float data: interleaved columns hide cross-record structure — a **columnar
  transpose** exposes it; row-major statistical coding misses it.

This is the same principle the HPC scientific compressors (SZ, ZFP, FPZIP) are built on,
and they get 10–100× where gzip gets 2×. mathpressor already lives in that family — it just
also ships general fallback + a live VFS, as one open tool.

## Honest caveats / the opportunity

- The data is synthetic (representative of sim/sensor/tabular/media, but clean). Real
  structured data is messier; expect smaller-but-still-real margins.
- The float wins came from a **generic columnar byte-plane transpose**, NOT a true float
  predictor. Dedicated tools (ZFP/SZ) with real float prediction would beat mathpressor on
  the float cases. **Adding a float/numeric predictor is the concrete next step** to turn
  "beats zstd/xz on floats" into "competes with the scientific specialists."
- Audio went `columnar`, not the LPC `audio` codec — LPC likely does better; the router
  picked columnar as smaller here, but the audio path may be under-tuned.

## The takeaway

mathpressor is **mis-positioned as a game/media compressor** (it loses there). Its
architecture — formula/predictive/columnar transforms + general fallback + live VFS — is a
**structured / scientific / numerical data** compressor, and on that data it beats the
mainstream tools while staying lossless and live. That's an open lane with a real edge,
versus the crowded one where it's behind.

---

## REAL-DATA VALIDATION (synthetic was too clean — here's the honest picture)

Re-ran on genuinely real files on the machine. The synthetic 7/8 did NOT transfer
directly, and the reasons are the actual lesson:

**Round 1 — real files as-is (mp wins 1/7):**
| real file | mp | xz-9e | note |
|---|---|---|---|
| DAW audio (.wav) | **5.57×** | 1.26× | **MP wins big** — LPC `audio` codec, real predictive signal |
| neural basis vectors (.npy f32) | 1.08× | 1.10× | tie — high-entropy, incompressible by ALL (bad test pick) |
| tabular .tsv / .csv (text) | 3.0× / 46× | 3.0× / 83× | xz wins — it's TEXT; regular mode uses zstd, xz uses LZMA |
| frametimes (.csv, text) | 5.0× | 5.5× | xz wins — numbers hidden in ASCII |

Two failure modes, both real: (1) **high-entropy data** (random embeddings/basis vectors)
compresses for nobody; (2) **text-encoded** numerical data hides its structure from the
formula codecs, and LZMA beats zstd on text.

**Round 2 — the SAME real telemetry, extracted to BINARY float columns (mp wins 9/11,
beats xz on 11/11):**
| real column (f32) | mp | zstd-19 | xz-9e | winner |
|---|---|---|---|---|
| elapsed (monotonic) | **4.18×** | 1.11× | 1.66× | **MP** (delta) |
| gpu_vram_used | **58.96×** | 57.4× | 40.2× | **MP** |
| gpu_temp | **45.74×** | 42.3× | 36.3× | **MP** |
| cpu_temp | **36.34×** | 36.2× | 28.5× | **MP** |
| gpu_power | **27.35×** | 25.1× | 15.9× | **MP** |
| fps / frametime / cpu_load / ram_used | narrow MP | | | **MP** |
| gpu_core_clock / gpu_load | 13.6× / 27.4× | **13.8× / 27.9×** | 9.3× / 20.4× | zstd (by a hair; MP still beats xz) |

**The verdict, honest and precise:** the structured-data edge is **real but conditional**.
mathpressor beats zstd AND xz on real numerical data **when (a) it's in binary numeric form
(raw float/int arrays — how HDF5/NetCDF/Parquet/time-series DBs actually store it) and (b)
it has genuine low-entropy structure (smooth/monotonic/slowly-varying)**. It does NOT help
on text-encoded numbers (use LZMA/CM) or high-entropy data (incompressible by all). The
single most important finding: **the same telemetry lost as text CSV and won 9/11 as binary
columns** — format is everything. Real audio (LPC) is also a genuine, strong win.

Caveat still standing: the binary float wins came mostly from `columnar` + delta, not a true
float predictor — ZFP/SZ would beat mathpressor on smooth float grids. Adding a real numeric
predictor remains the highest-leverage next step to own this lane.

---

## Float/numeric predictor (`math_float`, codec 0x12) — built + validated

Added a reversible, lossless predictor: **map each IEEE float's bits to a sort-order-
preserving integer → delta-code → byte-plane the residual**. It exposes value-domain
redundancy (consecutive values are *close*, not equal) that substring compressors can't see.
New comp_type, wired into the per-file router with the keep-smaller guard (strictly additive —
it only wins when it beats `columnar`/`fallback`, so zero regression). 74/74 tests pass incl. a
new f32/f64 involution test; bit-exact on real data (`verify-lossless.sh`: 14/14 LOSSLESS).

Where it helped (it improved the cleanest numerical cases over the old columnar result):

| dataset | float codec | old (columnar) | zstd-19 | xz-9e |
|---|---|---|---|---|
| real `elapsed` (monotonic) | **4.46×** | 4.18× | 1.11× | 1.66× |
| synthetic smooth field f32 | **2.40×** | 2.07× | 1.12× | 1.32× |
| synthetic monotonic f64 | **2.14×** | — | 1.60× | 1.70× |

Overall mathpressor now wins **12/14** vs zstd/xz on binary float data (2 losses to zstd by a
hair, beating xz on both).

**Honest read:** the predictor is a *real but incremental* gain — it clearly wins on
**monotonic sequences and smooth fields**, while `columnar` still wins on noisy telemetry
(delta amplifies low-mantissa noise there). The big real-data ratios (gpu_temp 45×, vram 59×)
still come from `columnar`/`fallback`. To go from "beats zstd/xz" to "competes with ZFP/SZ" on
smooth scientific grids, the next step is a **multidimensional (Lorenzo) predictor** that knows
the grid shape — the current 1D delta is the simplest form of the idea.

---

## 2D Lorenzo predictor — built (the scientific-grid step)

Extended `math_float` with a **2D Lorenzo predictor**: predict each cell from its
left + up − up-left neighbors (the stencil ZFP/SZ/FPZIP use; same idea as the image2d
MED predictor but for floats, in the monotonic-int domain so it's lossless). The row
width is **auto-detected** — it tries power-of-two widths that tile the array (+ the
square side), ranks them on a bounded prefix sample, and commits the best. New block adds
a `[u32 row_width]`; mode bit1 flags 2D. Still strictly keep-smaller-guarded; 74/74 tests
pass incl. a 1D+2D involution test; bit-exact on real + synthetic grids.

Float grids, mathpressor (2D Lorenzo) vs zstd/xz — **6/6 wins**:

| grid | 1D float codec | **2D Lorenzo** | zstd-19 | xz-9e |
|---|---|---|---|---|
| smooth field 1024² f32 | 2.40× | **3.16×** | 1.11× | 1.32× |
| smooth field 2048² f32 | — | **2.88×** | 1.09× | 1.27× |
| smooth field 1024² f64 | — | **1.66×** | 1.05× | 1.21× |
| real basis 7168×2048 f32 (high-entropy) | 1.08× | **1.17×** | 1.08× | 1.10× |
| real basis 3072×2048 f32 (high-entropy) | 1.08× | **1.17×** | 1.08× | 1.09× |
| noisy field 1024² f32 | (columnar 1.40×) | 1.40× | 1.11× | 1.27× |

On smooth fields the 2D predictor is **~2.4× smaller than xz** (3.16× vs 1.32×) — and even
the real high-entropy basis vectors flipped from tie to win. The 3.16× on a smooth lossless
field is in the range lossless scientific compressors (ZFP/FPZIP) report, though a direct
ZFP/SZ comparison could NOT be run here (offline; no network to install zfpy/libpressio) —
so "competes with the specialists" is *plausible from the ratios, not yet measured head-to-head*.
Next: 3D Lorenzo + a head-to-head vs ZFP/SZ when a build is available.
