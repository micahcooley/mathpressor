# FPS Chess runtime benchmark — runbook

Everything is built and tested. The only thing I can't do is **play the game**, so
these are the steps for you. Each scenario is one command + ~70 s of play.

## One-time setup (do this first)

In Steam: right-click **FPS Chess → Properties → Launch Options**, paste:

```
mangohud %command%
```

(That attaches MangoHud so frametimes get logged. Close the Properties window.)

## The three runs

Run these one at a time from the project dir
(`/home/micah/Desktop/Sylorlabs/mathpressor`). Each one drops the page cache,
sets up the asset source, **auto-launches the game**, and restores everything
when you quit. For each:

1. Wait for the main menu → start a match (vs bots is fine).
2. Once you're **moving in-game**, press **Shift_L + F2** (logs exactly 60 s).
3. Keep moving for ~60 s (try to do the *same* thing each run for a fair compare).
4. **Quit the game** normally. The script restores the install and prints a summary.

```bash
bash bench/scenario.sh native    # baseline: real installed files
bash bench/scenario.sh expand    # decoded-once from the .math (11s upfront, then native)
bash bench/scenario.sh fuse      # live: files decoded on demand from the .math
```

Order matters only in that `native` proves the pipeline works — do it first.

If the game **doesn't appear within ~3 min** in a run, the launch options aren't
set (see one-time setup) — just click **Play** in Steam manually; the script is
already waiting for the process and will pick it up.

## After all three

Tell me you're done. I'll read:
- `bench/run-*/summary.txt`   (load-to-process, disk bytes, peak RSS, decode time)
- `bench/run-fuse/mathfs.log` (per-asset on-demand decode timings)
- `bench/mangohud/*.csv`      (frametimes → avg / 1%-low FPS per scenario)

and write the comparison report.

## Safety / restore

The real install is **renamed aside** (`FPS Chess.real`) and restored on exit —
never deleted. If a run is interrupted and the install looks wrong, restore by hand:

```bash
cd "/home/micah/.local/share/Steam/steamapps/common"
fusermount3 -u "FPS Chess" 2>/dev/null
sudo umount "FPS Chess" 2>/dev/null
rmdir "FPS Chess" 2>/dev/null
mv "FPS Chess.real" "FPS Chess"
```
