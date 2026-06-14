# Mathpressor live-VFS benchmark — FPS Chess (real game, on Micah's PC)

> **→ In one line** — the actual numbers from packing a real 1 GB game to 320 MB and
> running it live off that file: it stayed at full speed (60 fps) with no stutters.
>
> *Shallow → deep: storage and the headline result first, then the byte-level details.*

**Goal:** ship a game compressed, run it *live* off the compressed archive without
inflating it to disk, and lose no runtime performance. Test corpus: the actual
Steam install of **FPS Chess** (UE4), 1.056 GiB across 28 files, dominated by one
**961 MB `.pak`** of game assets.

Hardware: Ryzen 5 5600X, RX 5600/5700-class GPU, 16 GB RAM, NVMe, Pop!\_OS kernel
7.0.11. Game runs under Proton Experimental.

---

## 1. Storage

| Representation | Size | Ratio | Random-access / live? |
|---|---|---|---|
| native (raw install) | 1,134,128,317 | 1.00× | — |
| mathpressor regular-max — **gzip** (original, buggy) | 404,485,395 | 2.80× | live, but big files weak |
| mathpressor regular-max — **whole-zstd** (after fix #1) | 282,765,724 | 4.01× | live, but no in-file seek |
| **mathpressor regular-max — chunked (shipping)** | **320,824,608** | **3.54×** | **live + true random access** |
| zstd -19 | 313,910,931 | 3.61× | cold archive |
| zstd --ultra -22 --long=27 | 280,661,345 | 4.04× | cold archive |
| xz -9 | 246,998,544 | 4.59× | cold archive |
| 7-Zip -mx9 (LZMA2) | 238,128,980 | 4.76× | cold archive |

The chunked archive (320 MB) is the one that runs live. It trades ~13% size vs
whole-file zstd for the ability to decode any region independently. Cold
archivers go smaller but cannot be run from — they must be fully expanded first.

**Every representation is bit-perfect.** Losslessness verified three independent
ways: the C-ABI live runner (28/28 byte-identical vs originals), a full `diff -r`
of the FUSE mount vs the install, and `unpack` + `diff -r`.

---

## 2. Two real bugs found and fixed

### Fix #1 — regular mode streamed large files with gzip, not zstd
Files over the 256 MB streaming threshold were compressed with `std.compress.gzip`
(DEFLATE, 32 KB window) regardless of the configured codec — a stopgap from before
the streaming-zstd path existed, never updated. On the 961 MB pak this gave 331 MB
where zstd-22 + long-distance matching gives 209 MB.

- Pak: **331 MB → 209 MB** (−37%); whole archive **404 MB → 283 MB** (−30%)
- Live decode of the pak also got **~2× faster** (zstd vs gzip inflate): 109 → 202 MB/s
- Routed `packFileParallel` / auto / solid to `addZstdStreamingFile`.

### Fix #2 — monolithic blob → independently-decodable chunks (the live VFS)
A whole-file zstd stream isn't seekable: to read *any* byte of the pak, the decoder
must inflate *all* of it. Measured cost of a single 4 KB read into the pak:

```
whole-blob:  8.14 s   ← the in-game freeze
chunked:     0.014 s  ← ~580× faster, ≈ native
```

New `math_chunked` container type: large files are stored as independently
zstd-compressed 4 MB chunks + a seek index (`addChunkedStreamingFile`,
`extractChunked`, `Reader.readChunk`). New ABI `mp_entry_chunk_size` /
`mp_read_chunk` decode a single chunk. A read maps to its chunk(s) only.

---

## 3. The live filesystem (`mathfs`)

A read-only FUSE filesystem that serves the game's tree by decoding **only the
4 MB chunk(s) a read touches**, into a bounded 320 MB RAM LRU — **nothing is ever
inflated to disk.** This is the distinction from "expand the archive, play,
recompress" (which costs the user the full disk and is no better than 7-zip): the
`.math` stays 320 MB on disk the whole time and the game reaches into it for what
it needs. Links libfuse3 + the Mathpressor C-ABI only.

### Automated read-pattern comparison (no game needed)
```
read pattern into the 961 MB pak            native(cold)  .math(cold)  .math(warm)
scattered 40×256K (~menu asset load 10 MB)     0.056 s       0.366 s      0.045 s
sequential 100 MB (~bundle load)               0.058 s       0.167 s      0.047 s
single 4 KB @ 500 MB (old freeze case)         0.012 s       0.014 s        —
```
First touch of a fresh region adds a sub-half-second; revisits are RAM-cached and
match or beat native. The catastrophic whole-file stall is gone.

---

## 4. Running the real game live off the `.math`

The game was launched through Steam/Proton with the Steam install path replaced by
the `mathfs` mount, so the real UE4 game read its assets live from the chunked
`.math`. (Proton's pressure-vessel sandbox intermittently bypassed the mount to the
real files; restarting Steam forces a fresh container that binds the mount. With
`allow_other` + the real files moved out of the Steam tree, routing is reliable.)

Confirmed live: the game decoded its own exe and **181 of 230 pak chunks on demand**
as it loaded and as menus were navigated — 255 chunk decodes, avg **8.7 ms** each.

### Framerate — identical to native
| run | median FPS | 1% low |
|---|---|---|
| **FUSE-chunked (live off .math)** | **60.1** | **48.9** |
| native (gameplay) | 59.8 | 39.1 |
| native-equiv (bypass) | 60.2 | 42.6 |

### Loading — freezes essentially eliminated
- 2.2 s of decode total, spread across the session as ms-scale bursts
- 366 of 368 captured frames smooth; **one 1.2 s hitch** on a single heavy menu
  load (a menu that pulled ~100 new chunks at once, decoded serially)
- Before chunking: an **8 s freeze on every pak touch**

---

## 5. Bottom line

On a real, unmodified Proton game:

- **Storage:** 1.06 GB → **320 MB** (3.54×), staying live and random-access.
- **Runtime:** **native 60 fps**, 1% lows no worse than native.
- **Loading:** the multi-second freezes are gone — replaced by mostly-smooth
  on-demand streaming, with one ~1 s residual hitch on the single heaviest load.
- **On disk:** the archive is never inflated; the game reaches into the compressed
  `.math` and pulls only the 4 MB chunks it needs.

This is the thing a normal compressed archive (or Steam) can't do: **more games in
storage, run live, no framerate loss.**

## 6. Smoothing the last hitch — concurrent decode + adaptive prefetch

The one residual ~1.2 s hitch was the heaviest menu loading ~100 chunks
**serially** under a single lock. mathfs was rebuilt with a concurrent cache
engine:

- **Parallel decode** — chunk decodes happen outside the global lock (refcounted
  cache entries pin against eviction), so many cores decode at once when the game
  issues concurrent reads.
- **Adaptive prefetch** — a worker pool decodes chunks *ahead* of the read head,
  but **only when the access is continuing a sequential run** (per-file last-chunk
  marker). Sequential asset loads get decode-ahead for free; scattered jumps pay
  nothing for wasted readahead.
- **Large RAM LRU** (default 1 GB) keeps the working set warm so revisits are
  instant. Bounded; still never inflated to disk.

Measured on the 961 MB pak (cold caches):

| read pattern | before (serial) | after |
|---|---|---|
| heavy menu burst — 120 scattered chunks, 12 threads | ~1.0 s | **0.26 s** |
| sequential 200 MB asset load, 1 thread | 0.66 s | **0.26 s** (2.6× via prefetch) |
| revisit (warm cache) | — | **~0.003 s** |

So the worst-case heavy load drops from ~1.2 s to ~0.26 s, sequential loads are
2.6× faster, and anything revisited is instant. Verified **bit-perfect under a
full `diff -r` through the concurrent engine** and under 3 concurrent 961 MB reads
with a cap small enough to force mid-read eviction (the refcount pinning is
race-safe). 52 unit tests pass.

### In-game confirmation (optimized engine)
Re-ran the real game off the optimized chunked `.math`, navigating menus:

| | worst frame | hitches >50 ms | median FPS | 1% low |
|---|---|---|---|---|
| before (single-lock serial) | 1226 ms | 1 | 60.1 | 48.9 |
| **after (parallel + adaptive prefetch + 1 GB cache)** | **22 ms** | **0** | 59.8 | 51.5 |
| native (reference) | 49 ms | 0 | 59.8 | ~42 |

**Zero hitches; worst frame 22 ms — smoother than the native reference capture.**
249 chunks decoded on demand into an 812 MB warm cache; every decode hidden
between frames. Running the full 1.06 GB game live from the 320 MB archive is now
indistinguishable from native, with nothing inflated to disk.

### Next step (optional)
Concurrent scattered decode scales ~2× across 12 threads, not ~12× — the limit is
FUSE request dispatch / global-lock contention, not decode CPU. Sharding the cache
lock and/or raising FUSE's worker-thread ceiling could push the worst-case cold
burst lower still, but in-game it is already hitch-free.

### Artifacts
- `bench/fpschess.regular-max.math` — the live (chunked) archive, 320 MB
- `bench/fpschess.regular-max.whole-zstd.math`, `.gzip-old.math` — fix-stage backups
- `src/mathfs.zig` — the live FUSE VFS; `src/vfs_runner.zig` — C-ABI live runner
- `bench/scenario.sh`, `bench/loadtest.sh` — runtime + read-pattern harnesses
- `bench/mangohud/*.csv` — frametime logs
