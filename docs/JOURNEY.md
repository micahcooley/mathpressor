# The journey: making a real game run live off a `.math`

> **👉 In one line** — how we got a real, full-size video game to run from a heavily
> shrunk file without it ever feeling slow — and the wrong turns along the way.
>
> *Reads top-to-bottom shallow → deep: the story first, the technical guts as you scroll.*

This is the development story behind the live VFS — what we set out to test, the
dead-ends, the bugs we found, and how the result landed. The hard numbers are in
[`../bench/REPORT.md`](../bench/REPORT.md); this is the narrative.

## The question

Mathpressor's regular mode is supposed to be *live-runnable*: ship a game
compressed and run it straight from the archive, decoding assets on demand, so you
fit more games in storage without losing performance. The test: take a real,
unmodified game and actually run it off a `.math` under Proton, then measure
whether you can tell the difference.

Corpus: the Steam install of **FPS Chess** (Unreal Engine 4) — 1.056 GiB across 28
files, 85% of it one **961 MB asset pak**. A hard, realistic case.

## Step 1 — storage, and a bug hiding in plain sight

First pack (regular max) came out at 404 MB. But plain `zstd -19` on the same files
was *smaller* (314 MB), which shouldn't happen — regular mode is supposed to beat
general compressors. Chasing it down: regular mode's large-file path
(`addBinaryStreamingFile`, for files over 256 MB) was compressing with **gzip /
DEFLATE**, not zstd — a stopgap from before the streaming-zstd path existed, with a
code comment cheerfully assuming "big files are usually already compressed so the
codec barely matters." For an *uncompressed* UE4 pak it mattered enormously: gzip's
32 KB window gave 331 MB where zstd-22 + long-distance matching gives 209 MB.

Switching the live pack paths to the existing `addZstdStreamingFile`: pak 331 → 209
MB, whole archive **404 → 283 MB**, and the live decode got ~2× faster (zstd vs gzip
inflate). The README's "#2, beats general compressors" claim was real all along; the
gzip path was masking it.

## Step 2 — a filesystem that decodes on demand

To run the game off the archive we needed the OS to see the game's files but have
them backed by the `.math`. Built `src/mathfs.zig`: a read-only **FUSE filesystem**
linking the public C-ABI, decoding entries on demand. Verified bit-perfect three
ways — a C-ABI runner (28/28 byte-identical), a full `diff -r` of the mount vs the
install, and `unpack` + `diff -r`.

## Step 3 — Proton fights back (the bypass)

Mount the `.math` over the Steam install path, launch the game… and `decode_count`
stayed **zero** while the game ran fine. Proton's **pressure-vessel** sandbox was
reaching the *real* files instead of our mount. Three things were needed to force it
through the FUSE mount reliably:

1. mount with `-o allow_other` (and `user_allow_other` in `/etc/fuse.conf`) so the
   sandbox's user namespace can read it;
2. move the real install **completely out of the Steam library tree** so there's no
   sibling to fall back to;
3. **restart Steam** before launching, to clear the warm container that had bound
   the old path.

With those, the game decoded its own exe and pak live from the archive — confirmed
by watching the decode count climb before committing to a play session.

(Two self-inflicted scares along the way: a restore step `mv`'d the backup *into* the
still-present install dir and nested it, and later left the install empty by writing
into a not-yet-unmounted read-only mount. Both were caught, the files were always
intact, and the restore logic was hardened to only ever plain-rename onto a clear
path — never write into a live mount.)

## Step 4 — it runs… and it freezes

First real run: the game launched and played at native 60 fps off the `.math` — but
loading anything new froze for several seconds. The cause was structural: the 961 MB
pak was one zstd blob, so reading *any* byte of it meant inflating the *whole* thing.
Measured: a single 4 KB read into the pak took **8.14 s**. (And the naive cache was
writing the whole decoded 961 MB to `/tmp` — exactly the "inflate to disk" model we
were trying to avoid.)

This is the key realization: a monolithic blob can't stream. You need
**independently decodable chunks**.

## Step 5 — chunked storage

Added `MATH_CHUNKED`: large files stored as independently zstd-compressed 4 MB
chunks plus a seek index, with an ABI to decode one chunk at a time
(`mp_read_chunk`). mathfs rewritten to decode only the touched chunk into a bounded
RAM cache — **never the whole file, never to disk.** The single-byte pak read went
from **8.14 s → 0.014 s** (~580×). Cost: ~13% larger archive (320 vs 283 MB) — the
price of random access, and worth it.

In-game: 60 fps, the multi-second freezes gone — but one **~1.2 s hitch** remained
on the single heaviest menu, where ~100 chunks were decoded one-after-another under a
single lock.

## Step 6 — making it indistinguishable

The last hitch was pure serialization. Rebuilt mathfs's cache engine:

- **parallel decode** — decodes run outside the global lock (refcounted entries pin
  against eviction), so many cores work at once;
- **adaptive prefetch** — a worker pool reads ahead, but *only* when the access is
  continuing a sequential run, so scattered menu jumps pay nothing for wasted
  readahead while sequential asset loads get decode-ahead for free;
- **large warm cache** (1 GB) so the working set stays resident and revisits are
  instant.

Re-ran the game. The result, menus before vs after:

| | worst frame | hitches > 50 ms | median FPS |
|---|---|---|---|
| before | 1226 ms | 1 | 60.1 |
| **after** | **22 ms** | **0** | 59.8 |

Zero hitches, worst frame 22 ms — *smoother than the native reference capture*
(49 ms). Then the real test: the developer played the `.math` version and a normal
native Steam launch back-to-back and **couldn't tell them apart** — which is exactly
the goal, since Steam has no idea `.math` exists; the native launch was the genuine
restored files (byte-verified before the test).

## Where it landed

On a real Proton game: **1.06 GB → 320 MB**, runs **live at native 60 fps with zero
hitches**, lossless, nothing ever inflated to disk. The thing a normal compressed
archive (or Steam) can't do: more games in storage, run live, no performance loss.

### Honest residual
Concurrent *scattered* cold decode scales only ~2× across 12 cores (FUSE request
dispatch + a single cache lock are the limit, not decode CPU). In-game it's already
hitch-free; sharding the cache lock could push the worst-case cold burst lower still.
