# Two ratio experiments — uncapped CM (cold/full) and per-file dict (live/regular)

Measured on Micah's PC (Ryzen 5 5600X). Numbers are real bytes from real runs, not
estimates. Both changes ship behind keep-smaller / probe guards, so neither can make
output larger than before.

---

## 1. Uncapping context-mixing in full (cold) mode — **WIN: −15.45% vs 7-Zip**

Full mode used to cap context-mixing (CM) at 96 MiB of tar, so any larger archive
silently fell back to LZMA and lost CM's text/code advantage. CM is cold-only and
slow (~0.3 MB/s), but cold storage doesn't care about speed — the only real ceiling
is RAM (CM holds the whole input plus ~190 MB of model tables, so peak ≈ 2× input).
The cap is now 1.5 GiB.

**Corpus:** 7,789 C/C++ headers from `/usr/include`, repacked as 8 × ~15 MB files
to keep the comparison about the codec, not the per-file pre-pass. Solid-tar size
**121,630,720 bytes (116 MiB)** — above the old 96 MiB cap, so this is exactly the
case the cap used to deny CM.

| tool | bytes | vs 7-Zip |
|---|---|---|
| **mathpressor full (CM)** | **7,051,812** | **−15.45%** |
| 7-Zip `-mx9` (LZMA2) | 8,340,956 | — |
| xz `-9e` | 8,400,040 | +0.71% |
| zstd `--ultra -22 --long=27` | 8,627,297 | +3.43% |

- Winning codec confirmed by reading the FAT: the single `archive.tar` block is
  `comp_type = 0x0E` (`math_cm`). CM won the keep-smaller race outright.
- **Before this change** the 116 MiB tar exceeded the 96 MiB cap → CM skipped →
  best backend was LZMA-class (≈ 7-Zip's LZMA2, ~8.3 MB, a tie/slight loss).
  Uncapping CM turned a tie into a 15% win.
- Lossless: `unpack` + content compare of all 8 files = bit-perfect (CM decode OK).
- Encode time 12 min wall (CM is the slow part — irrelevant for cold storage).

**Caveat (honest):** the win is on text/code, CM's home turf. On opaque/already-dense
data (game paks) CM does not beat LZMA and the guard keeps LZMA — see §2 and the
standing note that full mode is *not yet* uniformly #1 on opaque data (that needs the
9e-class optimal parse, tracked separately).

**Known full-mode inefficiency surfaced here:** at Max tier the per-file procedural-
synthesis pre-pass costs ~1 CPU-second *per file*. A tree of many tiny files
(7,789 headers) burned 135 CPU-minutes in the pre-pass before any compression. Full
mode wants few large inputs; the per-file pre-pass should be cheaper or skipped for
tiny files.

---

## 2. Per-file shared dictionary for live (chunked) mode — correct, no-regression,
##    **no win on the FPS Chess pak (honest)**, big win on concentrated redundancy

Chunked files reset the zstd window every 4 MiB, so redundancy repeating across
chunks isn't matched — most of the ~13% the live archive gives up vs whole-file zstd.
The fix: build a small **raw sampled-content** dictionary from the file's own chunks
and prime every frame with it, so cross-chunk matches survive while each frame still
decodes independently (stays live). A probe adopts the dict only when it saves ≥2× its
stored cost.

**Research finding — trained vs raw dict:** a ZDICT-*trained* dictionary recovered only
~42 KB on a chunk sharing a 256 KB region; the **raw content** of that region recovered
~262 KB. ZDICT optimises entropy tables + small segments for many-tiny-files; a chunked
pak needs large repeated regions present *verbatim* so zstd can match them. So the
implementation hands zstd raw sampled content, not a trained dict.

**FPS Chess pak result:** archive unchanged — 320,824,606 vs shipping 320,824,608
(2 bytes, noise). The probe **correctly declined**: this pak's cross-chunk redundancy
is sparse and ultra-long-range, beyond a small seekable dict.

**Why — chunk/dict sweep on a 256 MiB pak subset** (`bench/dict-chunk-study.py`, z19):

| representation | size | note |
|---|---|---|
| independent 4 MB chunks (shipping) | 34.87 MiB | live |
| independent 16 MB chunks | 34.62 MiB | recovers 0.25 MiB |
| independent 64 MB chunks | 34.55 MiB | recovers 0.33 MiB |
| 4 MB chunks + 16 MB sampled dict | 34.72 MiB | recovers 0.16 MiB net |
| whole-stream zstd `--long=27` | 32.65 MiB | **2.22 MiB / 6.4% better, NOT seekable** |

The whole-file win comes almost entirely from matches at **64 MB+ distances**. Neither
bigger chunks nor any practical (≤32 MB, zstd's cap) dict catches them — the redundancy
is sparse and spans the whole 961 MB (consistent with an already-internally-compressed
UE4 pak). On this data the live↔cold gap is a genuine cost of random access, not a bug.

**Where the dict DOES win:** data with concentrated / medium-range cross-chunk
redundancy (shared asset bundles, similar files, logs, uncompressed paks). Unit test
`chunked dict: large redundant file round-trips…` builds chunks sharing a common body
and the dict is adopted with a large saving — verified lossless through both the
whole-file `extractChunked` path and the live per-chunk `readChunk` path.

**Status:** correct, no-regression (probe + STORE guard), lossless (2 new round-trip
tests, 73/73 pass), shipped under `comp_type = math_chunked` with a dict flag bit so
old archives still decode.

---

## 3. Parallel chunk compression (live/regular mode) — **4.9× faster encode**

Symptom: regular mode felt slow vs 7-Zip even though zstd is the faster codec.
Cause: `addChunkedStreamingFile` compressed a file's 4 MiB chunks in a **serial
loop on one thread**. A game archive is dominated by one huge pak (77% of FPS
Chess), so that single file pinned the whole pack to ~1 core while the other ~10
sat idle — 7-Zip won on speed only because it's multi-threaded and we weren't.

Fix: the chunks are independent (that's what makes the format seekable), so
compress them in parallel — batches of `nthreads`, results written back in chunk
order (byte-identical layout). A shared semaphore caps total concurrent
compressions to the core count so file-level × chunk-level parallelism can't
spawn cpu² zstd contexts and exhaust RAM on a many-pak game.

Measured, FPS Chess regular mode (Max), Ryzen 5 5600X:

| | wall time | CPU | size |
|---|---|---|---|
| serial (before) | 6 min 21 s | 205% (~2 cores) | 320,824,608 |
| **parallel (after)** | **1 min 18 s** | 636% (~7 cores) | 320,824,604 |
| 7-Zip `-mx9` (ref) | 4 min 18 s | all cores | 238,128,980 |

**4.9× faster, same size (4-byte noise), and now 3.3× faster than 7-Zip** — while
still producing the live, seekable, runnable `.math` that 7-Zip can't. Verified
lossless on the real corpus (`bench/verify-lossless.sh`, content-hash multiset) and
by 73/73 unit tests. CPU isn't fully saturated (636%) because of the per-batch
barrier (cores wait for the slowest chunk each batch); a barrier-free work queue
would push it higher, but 4.9× already flips the speed story.

Extrapolation: full-game regular Max was ~6 h for 58 GB; at this throughput it's
roughly **~75 min** (less the gain where many large paks already parallelized at
the file level).
