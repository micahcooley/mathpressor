#!/bin/bash
# loadtest.sh — automated native-vs-.math read-pattern comparison, no game needed.
# Simulates how a game pulls assets out of the pak (scattered seeks + sequential
# runs) and times it through (a) the real file on disk and (b) the chunked .math
# served live by mathfs. This is the load-latency a menu transition pays.
set -u
cd "$(dirname "$0")/.."
PAKREL="FPSChess/Content/Paks/FPSChess-WindowsNoEditor.pak"
G="/home/micah/.local/share/Steam/steamapps/common/FPS Chess"
NATIVE="$G/$PAKREL"
MNT=/tmp/loadtest_mnt
ARCHIVE=bench/fpschess.regular-max.math

# 40 fixed 256 KB-block offsets scattered across the 961 MB pak (deterministic,
# same for both sides). Block size 256 KB → pak has ~3668 blocks.
OFFS=(12 305 588 911 1203 1499 1788 2050 2371 2670 2999 3301 3502 3650 88 740 1620 2890 410 1950 60 999 2222 3333 175 820 1444 2777 333 1111 2555 3490 240 690 1360 2480 3120 505 1730 2960)
BS=262144

timer_start() { date +%s.%N; }
elapsed() { echo "$(date +%s.%N) - $1" | bc; }
drop() { sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; }

scatter() { # $1 = path to pak (native file or mount)
  local p="$1"
  for o in "${OFFS[@]}"; do
    dd if="$p" of=/dev/null bs=$BS skip=$o count=1 2>/dev/null
  done
}
seqread() { # $1 = path, read first 100 MB sequentially
  dd if="$1" of=/dev/null bs=1M count=100 2>/dev/null
}

echo "=== mounting chunked .math via mathfs ==="
fusermount3 -u "$MNT" 2>/dev/null; rm -rf "$MNT"; mkdir -p "$MNT"
./zig-out/bin/mathfs "$ARCHIVE" "$MNT" -f -o ro > /tmp/loadtest_mathfs.log 2>&1 &
until mountpoint -q "$MNT"; do sleep 0.3; done
FUSEPAK="$MNT/$PAKREL"
echo "mounted."
echo ""

printf "%-34s %12s\n" "TEST" "wall (s)"
printf '%.0s-' {1..48}; echo

# --- scattered "menu asset" reads: 40 × 256 KB at random offsets (~10 MB) ---
drop
t=$(timer_start); scatter "$NATIVE";   printf "%-34s %12.3f\n" "scattered 40×256K  NATIVE(cold)"   "$(elapsed "$t")"
t=$(timer_start); scatter "$FUSEPAK";  printf "%-34s %12.3f\n" "scattered 40×256K  .math(cold)"    "$(elapsed "$t")"
t=$(timer_start); scatter "$FUSEPAK";  printf "%-34s %12.3f\n" "scattered 40×256K  .math(warm)"    "$(elapsed "$t")"

echo ""
# --- sequential 100 MB "load a big asset bundle" ---
drop
t=$(timer_start); seqread "$NATIVE";   printf "%-34s %12.3f\n" "sequential 100MB   NATIVE(cold)"   "$(elapsed "$t")"
t=$(timer_start); seqread "$FUSEPAK";  printf "%-34s %12.3f\n" "sequential 100MB   .math(cold)"     "$(elapsed "$t")"
t=$(timer_start); seqread "$FUSEPAK";  printf "%-34s %12.3f\n" "sequential 100MB   .math(warm)"     "$(elapsed "$t")"

echo ""
# --- single first-touch read (the old whole-file freeze case) ---
fusermount3 -u "$MNT" 2>/dev/null; sleep 1
./zig-out/bin/mathfs "$ARCHIVE" "$MNT" -f -o ro > /tmp/loadtest_mathfs.log 2>&1 &
until mountpoint -q "$MNT"; do sleep 0.3; done
drop
t=$(timer_start); dd if="$NATIVE" of=/dev/null bs=4096 skip=128000 count=1 2>/dev/null; printf "%-34s %12.3f\n" "single 4KB @500MB  NATIVE(cold)" "$(elapsed "$t")"
t=$(timer_start); dd if="$FUSEPAK" of=/dev/null bs=4096 skip=128000 count=1 2>/dev/null; printf "%-34s %12.3f\n" "single 4KB @500MB  .math(cold)" "$(elapsed "$t")"

fusermount3 -u "$MNT" 2>/dev/null; rm -rf "$MNT"
echo ""
echo "(.math stays 320 MB on disk throughout; nothing inflated. cold = first touch,"
echo " warm = chunk already in mathfs's RAM cache.)"
