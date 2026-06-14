# What's genuinely new here (and what stands on prior art)

> **→ In one line** — an honest answer to "is any of this actually new?" Short version:
> the building blocks mostly already exist; the *way they're combined* (and a few
> measured wins + a working game demo) is the new part.
>
> *Shallow → deep: the plain summary first, the per-type numbers and prior-art table below.*

An honest map of Mathpressor's contributions. The headline: Mathpressor's value is a
**novel system** — procedural synthesis and traditional compression unified into one
auto-routing, live, random-access container — plus **measured wins on structured
data** and a **working demonstration** of a real Proton game running off the archive
at native FPS. The individual algorithms are mostly known; the *assembly*, the
*implementation*, and several *empirical findings* are the work.

---

## 1. What Mathpressor actually delivers

### 1.1 A system with no direct published equivalent
One container that, **per asset**, picks the best of:
- **procedural synthesis** — store a tiny generator program when it reproduces the
  bytes exactly (demoscene-style), *or*
- a stack of **traditional routes** — reversible filters (delta / x86 BCJ / RIP) →
  context-mixing / LZMA / zstd — keeping whichever is smallest,

…and then serves the whole archive as a **live, chunked, random-access VFS** so a host
reads assets on demand with **nothing inflated to disk**.

Each ingredient exists in isolation (see §3). What this review did **not** find is any
prior system that combines *procedural-synthesis-as-a-compression-route* with
*traditional-compression fallback* inside a *live random-access VFS*. That integrated
whole is a genuine **system-design** contribution — engineering novelty, not a new
algorithm, and valuable on its own terms.

### 1.2 It actually beats 7-Zip and xz on structured data (measured)
Full mode's context-mixing coder plus domain-specific reversible transforms win on the
data they're built for. Bytes, smaller is better:

| Data type | 7-Zip `-mx9` | `xz -9` | **Mathpressor full** | Margin vs 7z |
|---|---|---|---|---|
| Text / source code (175 KB Zig) | 35,259 | 35,220 | **29,689** | **−16 %** |
| x86-64 ELF binary (8 MB python3) | 1,871,374 | 2,116,072 | **1,771,949** | **−5.3 %** |
| Raw image (332 KB PPM raster) | 253,080 | 253,188 | **247,212** | **−2.3 %** |

These are real, reproducible wins: context mixing beats LZMA on text/code, and the
x86 RIP/BCJ filters + 2D image predictor expose redundancy general compressors don't
model. **Even the live (regular) mode beats 7z/xz on x86 binaries** (BCJ2: 1.86 MB vs
7z 1.87 MB / xz 2.12 MB) while staying random-access.

### 1.3 …and it's honest about where it loses
- **Opaque / already-dense data:** on the 1.06 GB FPS Chess corpus (an Unreal pak that
  resists modeling), 7-Zip (238 MB) and xz (247 MB) beat live mode (283–320 MB). Live
  mode's edge there is *being runnable*, not smaller.
- **Audio:** on a small 16-bit PCM sample, 7-Zip (5,791 B) edged full mode (6,020 B).
  The README's multi-file WAV win (LPC vs solid 7z) was not reproduced here and is
  data-dependent.

So the true, defensible claim is **not** "beats everyone on ratio." It is: *full mode
beats general compressors on text, code, and images via context-mixing + domain
transforms; live mode trades some ratio for random-access and on-demand decode.*

### 1.4 Implementation properties that are real value
- **100 % Zig**, no vendored C/C++ — only `libzstd`/`liblzma`/`libfuse3` linked.
- **Deterministic across architectures** — bit-identical output verified on x86-64 LE,
  big-endian s390x, and aarch64 (all multi-byte operands decoded little-endian
  explicitly). A reproducibility guarantee SquashFS/DwarFS don't foreground.
- **A live VFS proven on a real, unmodified game** under Proton (see §2).

---

## 2. Empirical findings (things learned by experimenting, not in the literature)

1. **Proton's pressure-vessel bypasses a FUSE mount** swapped into a Steam install
   path — it reads the real files instead. The recipe to force routing through the
   mount: mount `-o allow_other` (with `user_allow_other` in `/etc/fuse.conf`), move
   the real install **out of the Steam library tree**, **and restart Steam** to clear
   the warm container. Undocumented as far as this review found — the most useful
   *practical* takeaway for running any Proton game off a userspace VFS.
2. **Chunk size is a measured 3-way tradeoff.** 4 MB chunks cost ~13 % archive size vs
   whole-file zstd (320 vs 283 MB on the corpus) but turn a single-byte read of a
   961 MB pak from an **8.14 s** whole-file inflate into **0.014 s** (~580×).
3. **Adaptive prefetch beats unconditional prefetch.** Read-ahead only on detected
   sequential runs: scattered heavy load 0.23 s (vs 0.32 s always-on), sequential
   200 MB load 0.26 s (vs 0.66 s with no prefetch). Always-on prefetch *hurts*
   scattered access by spending cores on unused readahead.
4. **A real Unreal/Proton game runs off the live archive at native FPS, zero hitches**
   (median 59.8 fps, worst frame 22 ms; 1.06 GB → 320 MB, nothing inflated to disk).
   See [`../bench/REPORT.md`](../bench/REPORT.md).
5. **A latent codec bug, quantified.** Live mode was streaming >256 MB files with
   gzip/DEFLATE instead of zstd; on the uncompressed UE4 pak that cost ~37 %
   (331 → 209 MB).

---

## 3. Standing on the shoulders of (the prior art, honestly)

None of the underlying *algorithms* is a new invention, and saying so up front is what
makes the claims above credible:

| Mathpressor mechanism | Established prior art |
|---|---|
| Procedural asset = generator program | Demoscene **.kkrieger / .werkkzeug3** (2004); OpenKTG |
| Compressed read-only FUSE FS, on-demand block decode | **SquashFS** (2002), **DwarFS**, CromFS |
| Running a Wine/Proton game off a compressed image | **AppImage** (SquashFS), **GameImage** |
| Independently-decodable chunks + seek index | **zstd "seekable format"**, Fuchsia BlobFS, bgzip, dictzip |
| Delta / BCJ / BCJ2 filters | LZMA SDK / 7-Zip |
| x86-64 RIP-relative filter | encode.su disasm-filter work; `[reg+disp32]` rewriting; ~10 % over stock BCJ is a known result |
| Context-mixing coder | **PAQ / lpaq / zpaq / cmix** |
| Adaptive prefetch / sequential readahead | Linux readahead framework; "adaptive synchronous prefetch" |

The contribution is not inventing these — it is **assembling them into one coherent
live game-VFS, in pure Zig, and proving it on a real game**, plus the per-type wins and
empirical findings above.

---

## 4. How to position it

- **Lead with:** the live game demo, the system integration, and the *structured-data*
  ratio wins (text −16 %, code −5 %, image −2 % vs 7-Zip).
- **Claim precisely:** "beats general compressors on text/code/images; competitive
  while staying live and random-access on the rest." Not "beats everyone."
- **Credit the prior art openly** — it makes the real wins believable rather than
  hand-wavy.

*Method: web/literature review, June 2026 (SquashFS/DwarFS docs, zstd seekable-format
spec, Farbrausch/.kkrieger history, encode.su x86-filter + PAQ threads, OS readahead
literature) plus the per-type benchmark in this repo. No source describing the specific
procedural+traditional auto-routing live-VFS combination was found.*

---

## 5. Pure-Zig LZMA encoder (in progress — the opaque-data lever)

On truly-opaque data (a monolithic game `.pak`) full mode's only loss to 7-Zip is
that 7-Zip's LZMA *optimal parser* is ~0.3–6% tighter than liblzma's, depending on
data. liblzma's encoder is a black box we can't improve, and 7-Zip's is C++ we won't
vendor (pure-Zig constraint). So we're growing our own LZMA encoder whose parse we
control — `src/lzma_enc.zig`. It emits the **standard `.lzma` stream**, so *decode is
free* (liblzma reads it) and every result is round-trip-verified with
`xz -d --format=lzma`.

Built and verified so far (all bit-perfect):
- LZMA range coder + full probability model + 12-state machine.
- **BT4** binary-tree match finder (closest-distance-per-length, as liblzma/7-Zip use).
- **Optimal parse**: a windowed forward DP over a price model, with a long-match
  early-stop so it never truncates the 273-byte-capped matches at a window boundary.

Standing vs liblzma `-9e`: **text −0.88 % (we win), code +2.3 %, structured +5.0 %,
opaque +5.5 %.** Honest findings from the build:
- The remaining opaque gap is **not** match-finding (BT4 produces byte-identical output
  to a depth-1024 hash chain) and **not** window size — it's parse-*modeling* depth:
  9e's `GetOptimum` evaluates "complex" candidates (match→literal→rep0 combinations,
  periodic price refresh) a single-state-per-node DP can't reach. That port is the
  remaining work to take full mode past 7-Zip on opaque data.
- Side-finding: on this opaque data liblzma `-9` (445,945 B) actually *beats* `-9e`
  (449,490 B) and ~ties 7-Zip (445,715 B) — "extreme" effort can hurt on dense data.

This is a multi-stage build; what's below the complex-candidate layer is correct and
tested. `mathpressor lzmaenc <file>` runs it and prints the comparison.
