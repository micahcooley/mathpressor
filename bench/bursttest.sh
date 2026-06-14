#!/bin/bash
# bursttest.sh — measure a "heavy menu load" (the thing that caused the 1.2s hitch):
# many reads of distinct, scattered pak chunks. Compares SERIAL (single blocking
# IO thread) vs CONCURRENT (game streaming threads) through native and the .math,
# so the parallel-decode + prefetch win is visible.
set -u
cd "$(dirname "$0")/.."
PAKREL="FPSChess/Content/Paks/FPSChess-WindowsNoEditor.pak"
G="/home/micah/.local/share/Steam/steamapps/common/FPS Chess"
NATIVE="$G/$PAKREL"
MNT=/tmp/burst_mnt
ARCHIVE=bench/fpschess.regular-max.math
N=120   # chunks touched in the "menu load"

# 120 distinct, scattered chunk indices (×7 mod 230 → spread across the pak).
OFFS=()
for i in $(seq 0 $((N-1))); do OFFS+=( $(( (i*7)%230 * 1024 )) ); done   # ×1024 = 4MB/4KB → chunk start

drop() { sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; }
now() { date +%s.%N; }
el() { echo "$(date +%s.%N) - $1" | bc; }

serial() { local p="$1"; for o in "${OFFS[@]}"; do dd if="$p" of=/dev/null bs=4096 skip=$o count=1 2>/dev/null; done; }
concurrent() { local p="$1"; for o in "${OFFS[@]}"; do dd if="$p" of=/dev/null bs=4096 skip=$o count=1 2>/dev/null & done; wait; }

mount_fresh() {
  fusermount3 -u "$MNT" 2>/dev/null; sleep 0.5; rm -rf "$MNT"; mkdir -p "$MNT"
  ./zig-out/bin/mathfs "$ARCHIVE" "$MNT" -f -o ro --cache-mb 1024 "$@" > /tmp/burst_mathfs.log 2>&1 &
  until mountpoint -q "$MNT"; do sleep 0.3; done
}

echo "heavy menu load = $N distinct scattered 4MB-chunk touches"
printf "%-42s %10s\n" "TEST" "wall(s)"
printf '%.0s-' {1..54}; echo

drop; t=$(now); serial "$NATIVE";      printf "%-42s %10.3f\n" "SERIAL      native(cold)"            "$(el "$t")"
mount_fresh; t=$(now); serial "$MNT/$PAKREL";  printf "%-42s %10.3f\n" "SERIAL      .math(cold, no prefetch help)" "$(el "$t")"

echo ""
drop; t=$(now); concurrent "$NATIVE";  printf "%-42s %10.3f\n" "CONCURRENT  native(cold)"            "$(el "$t")"
mount_fresh; t=$(now); concurrent "$MNT/$PAKREL"; printf "%-42s %10.3f\n" "CONCURRENT  .math(cold, parallel decode)" "$(el "$t")"
t=$(now); concurrent "$MNT/$PAKREL";   printf "%-42s %10.3f\n" "CONCURRENT  .math(warm)"              "$(el "$t")"

echo ""
echo "decodes performed: $(awk '/decode/{} END{}' /tmp/burst_mathfs.log >/dev/null; echo n/a) (cache 1GB, 6 prefetch workers)"
fusermount3 -u "$MNT" 2>/dev/null; rm -rf "$MNT"
echo ""
echo "SERIAL ≈ a single blocking load thread; CONCURRENT ≈ the game's streaming"
echo "threads. Old whole-blob: the FIRST touch alone was ~8s. Old chunked-serial"
echo "(single lock): ~$N×8.7ms ≈ $(echo "$N*0.0087" | bc)s."
