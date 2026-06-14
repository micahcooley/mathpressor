#!/bin/bash
# scenario.sh — run FPS Chess in one of three asset-delivery modes and collect
# launch/load, memory, and disk-I/O numbers while MangoHud logs frametimes.
#
#   native : game reads its real installed files (baseline)
#   fuse   : game reads files live from the .math via the mathfs FUSE mount
#   expand : game reads files decoded once from the .math into a temp dir
#
# Usage:  bash bench/scenario.sh <native|fuse|expand>
#
# The real Steam install is NEVER deleted — for fuse/expand it is renamed aside
# and restored on exit (even on Ctrl-C / error) via a trap. You play the game;
# the script handles setup, sampling, and teardown.
set -u

MODE="${1:-}"
case "$MODE" in native|fuse|expand) ;; *) echo "usage: $0 <native|fuse|expand>"; exit 1;; esac

PROJ="/home/micah/Desktop/Sylorlabs/mathpressor"
ARCHIVE="$PROJ/bench/fpschess.regular-max.math"
COMMON="/home/micah/.local/share/Steam/steamapps/common"
GAME="$COMMON/FPS Chess"
# Real install is moved OUT of the Steam library tree during fuse/expand runs, so
# Proton's container can't reach the original files as a sibling — the only thing
# at the game path is the live mount. Restored on exit.
REAL="/tmp/fpschess_real_backup"
EXPAND_DIR="/tmp/fpschess_expanded"
CACHE_DIR="/tmp/mathfs_cache"
MATHFS="$PROJ/zig-out/bin/mathfs"
APPID=2021910
GAMEPROC="FPSChess-Win64-Shipping.exe"
OUT="$PROJ/bench/run-$MODE"
mkdir -p "$OUT" "$PROJ/bench/mangohud"
DISK=nvme0n1

mathfs_pid=""
sampler_pid=""

restore() {
  echo ">> restoring install dir..."
  [ -n "$sampler_pid" ] && kill "$sampler_pid" 2>/dev/null
  [ -n "$mathfs_pid" ] && kill "$mathfs_pid" 2>/dev/null
  sleep 1   # let the killed mathfs release the mount before we unmount
  # Fully unmount whatever is at GAME (fuse mount or bind), with retries.
  for _ in $(seq 1 8); do
    mountpoint -q "$GAME" 2>/dev/null || break
    fusermount3 -u "$GAME" 2>/dev/null || sudo umount -l "$GAME" 2>/dev/null
    sleep 1
  done
  if [ -d "$REAL" ]; then
    if mountpoint -q "$GAME" 2>/dev/null; then
      # Never touch a live mount — the real files are safe; tell the user how to finish.
      echo "!! $GAME is STILL MOUNTED — not touching it. Real files safe at: $REAL"
      echo "!! manual fix:  fusermount3 -u '$GAME'; rmdir '$GAME'; mv '$REAL' '$GAME'"
    else
      # Drop GAME only if it's an empty dir, then plain-rename the backup over it.
      [ -d "$GAME" ] && [ -z "$(ls -A "$GAME" 2>/dev/null)" ] && rmdir "$GAME" 2>/dev/null
      if [ ! -e "$GAME" ]; then
        mv "$REAL" "$GAME" && echo ">> install restored OK"
      else
        # NEVER write into GAME (it nests/clobbers) — leave backup + instructions.
        echo "!! $GAME exists and is not an empty dir — not moving backup (would nest)."
        echo "!! Real files safe at: $REAL"
        echo "!! manual fix:  rmdir '$GAME' 2>/dev/null; mv '$REAL' '$GAME'"
      fi
    fi
  fi
  mountpoint -q "$GAME" 2>/dev/null && echo "!! WARNING: $GAME still mounted"
}
trap restore EXIT INT TERM

sectors_read() { awk -v d="$DISK" '$3==d {print $6}' /proc/diskstats; }

drop_caches() { sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; echo ">> page cache dropped"; }

wait_for_proc() { # $1 = name, $2 = timeout s
  local n="$1" t="${2:-120}" i=0
  while ! pgrep -f "$n" >/dev/null; do sleep 1; i=$((i+1)); [ "$i" -ge "$t" ] && return 1; done
  return 0
}

# ---- per-mode setup --------------------------------------------------------
echo "=== scenario: $MODE ==="
case "$MODE" in
  native)
    : # nothing to swap
    ;;
  fuse)
    [ -d "$REAL" ] && { echo "!! $REAL already exists — clean up first"; exit 1; }
    rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR"
    mv "$GAME" "$REAL"
    mkdir "$GAME"
    echo ">> mounting mathfs..."
    "$MATHFS" "$ARCHIVE" "$GAME" --cache-dir "$CACHE_DIR" -f -o ro,allow_other,kernel_cache,entry_timeout=60,attr_timeout=60 > "$OUT/mathfs.log" 2>&1 &
    mathfs_pid=$!
    until mountpoint -q "$GAME"; do sleep 0.3; done
    echo ">> mathfs mounted at install path"
    ;;
  expand)
    if [ ! -d "$EXPAND_DIR/FPS Chess" ]; then
      echo ">> expanding .math -> $EXPAND_DIR (one-time decode)..."
      rm -rf "$EXPAND_DIR"; mkdir -p "$EXPAND_DIR"
      /usr/bin/time -f "EXPAND_DECODE %e s" "$PROJ/zig-out/bin/mathpressor" unpack "$ARCHIVE" "$EXPAND_DIR/FPS Chess" 2> "$OUT/expand.time" || { echo "unpack failed"; cat "$OUT/expand.time"; exit 1; }
      cat "$OUT/expand.time"
    fi
    [ -d "$REAL" ] && { echo "!! $REAL already exists — clean up first"; exit 1; }
    mv "$GAME" "$REAL"
    mkdir "$GAME"
    sudo mount --bind "$EXPAND_DIR/FPS Chess" "$GAME"
    echo ">> expanded dir bind-mounted at install path"
    ;;
esac

# ---- sampler (RSS + disk) --------------------------------------------------
sec0=$(sectors_read)
( peak=0; peakmf=0
  while true; do
    pid=$(pgrep -f "$GAMEPROC" | head -1)
    if [ -n "$pid" ]; then
      r=$(awk '/VmRSS/{print $2}' /proc/$pid/status 2>/dev/null); r=${r:-0}
      [ "$r" -gt "$peak" ] && peak=$r
    fi
    if [ -n "$mathfs_pid" ]; then
      m=$(awk '/VmRSS/{print $2}' /proc/$mathfs_pid/status 2>/dev/null); m=${m:-0}
      [ "$m" -gt "$peakmf" ] && peakmf=$m
    fi
    echo "$(date +%s.%N) game_rss_kb=$peak mathfs_rss_kb=$peakmf" >> "$OUT/sample.log"
    sleep 0.5
  done ) &
sampler_pid=$!

drop_caches

echo ""
echo "############################################################"
echo "#  LAUNCHING FPS Chess ($MODE)."
echo "#  1) Wait for the main menu, then START A MATCH (vs bots is fine)."
echo "#  2) Once you are MOVING in-game, press  Shift_L + F2  to log 60s."
echo "#  3) Keep playing/moving ~60s (MangoHud auto-stops the log)."
echo "#  4) QUIT the game normally. This script then restores everything."
echo "############################################################"
echo ""
t_launch=$(date +%s.%N)
echo "$t_launch launch" > "$OUT/timeline.log"
steam "steam://rungameid/$APPID" >/dev/null 2>&1 &

echo ">> waiting for game process ($GAMEPROC)..."
if wait_for_proc "$GAMEPROC" 180; then
  t_proc=$(date +%s.%N)
  echo "$t_proc proc_appeared" >> "$OUT/timeline.log"
  echo ">> game process up after $(echo "$t_proc - $t_launch" | bc)s — play now."
else
  echo "!! game process never appeared (180s). Did you set launch options to: mangohud %command% ?"
fi

# Wait until the game exits.
echo ">> waiting for you to quit the game..."
while pgrep -f "$GAMEPROC" >/dev/null; do sleep 2; done
t_exit=$(date +%s.%N)
echo "$t_exit proc_exited" >> "$OUT/timeline.log"

sec1=$(sectors_read)
kill "$sampler_pid" 2>/dev/null; sampler_pid=""

# ---- summarize -------------------------------------------------------------
bytes_read=$(( (sec1 - sec0) * 512 ))
peak_game=$(awk '{for(i=1;i<=NF;i++) if($i ~ /game_rss_kb=/){split($i,a,"=");v=a[2]}} END{print v}' "$OUT/sample.log" 2>/dev/null)
peak_mf=$(awk '{for(i=1;i<=NF;i++) if($i ~ /mathfs_rss_kb=/){split($i,a,"=");v=a[2]}} END{print v}' "$OUT/sample.log" 2>/dev/null)

{
  echo "mode=$MODE"
  echo "launch_to_proc_s=$(echo "$t_proc - $t_launch" | bc 2>/dev/null)"
  echo "disk_bytes_read=$bytes_read"
  echo "peak_game_rss_kb=${peak_game:-?}"
  echo "peak_mathfs_rss_kb=${peak_mf:-0}"
  if [ "$MODE" = "fuse" ]; then
    echo "decode_total_ms=$(awk '/^DECODE/{gsub(/ms/,"",$2); s+=$2} END{printf "%.1f", s}' "$OUT/mathfs.log" 2>/dev/null)"
    echo "decode_count=$(grep -c '^DECODE' "$OUT/mathfs.log" 2>/dev/null)"
  fi
} | tee "$OUT/summary.txt"

echo ">> newest MangoHud logs:"; ls -t "$PROJ/bench/mangohud"/*.csv 2>/dev/null | head -3
echo "=== scenario $MODE complete ==="
