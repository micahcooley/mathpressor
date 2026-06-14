#!/bin/bash
set -e
TAR=/tmp/fpschess.tar
OUT=bench/baselines.csv
echo "tool,bytes,seconds" > "$OUT"
run() {
  local name="$1"; shift
  local start=$(date +%s.%N)
  local bytes
  bytes=$("$@" | wc -c)
  local end=$(date +%s.%N)
  local secs=$(echo "$end - $start" | bc)
  printf "%-22s %12d bytes  %8.1f s\n" "$name" "$bytes" "$secs"
  echo "$name,$bytes,$secs" >> "$OUT"
}
echo "== zstd -19 -T0 =="
run "zstd-19"            zstd -19 -T0 -c "$TAR"
echo "== zstd --ultra -22 --long=27 -T0 =="
run "zstd-22-ultra-long" zstd --ultra -22 --long=27 -T0 -c "$TAR"
echo "== xz -9 -T0 =="
run "xz-9-T0"           xz -9 -T0 -c "$TAR"
echo "== 7z -t7z -mx9 (LZMA2) =="
rm -f /tmp/fps7z.7z
s=$(date +%s.%N)
7z a -t7z -mx9 -mmt12 /tmp/fps7z.7z "$TAR" >/dev/null
e=$(date +%s.%N)
b=$(stat -c%s /tmp/fps7z.7z)
printf "%-22s %12d bytes  %8.1f s\n" "7z-mx9" "$b" "$(echo "$e-$s"|bc)"
echo "7z-mx9,$b,$(echo "$e-$s"|bc)" >> "$OUT"
rm -f /tmp/fps7z.7z
echo "== DONE =="
cat "$OUT"
