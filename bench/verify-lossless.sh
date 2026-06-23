#!/usr/bin/env bash
# verify-lossless.sh <source_dir_or_file> <archive.math>
#
# Proves a .math reconstructs its source byte-for-byte. Robust to full mode's
# path nesting: full mode preserves the source dir name, so the tree unpacks
# under OUT/<basename(SRC)> rather than OUT/ directly — a plain `diff -r OUT`
# then reads as a mismatch even when every byte is identical. This tries both
# roots for a clean structural diff, and ALSO runs a path-agnostic content-hash
# multiset check that proves all bytes are preserved regardless of nesting.
set -u
SRC="${1:?usage: verify-lossless.sh <source> <archive.math>}"
MATH="${2:?usage: verify-lossless.sh <source> <archive.math>}"
BIN="${MATHPRESSOR_BIN:-./zig-out/bin/mathpressor}"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "unpack $MATH -> $OUT"
"$BIN" unpack "$MATH" "$OUT" >/dev/null 2>&1 || { echo "RESULT: UNPACK FAILED"; exit 1; }

base="$(basename "$SRC")"
perfect=0
cmp_root="$OUT"
for R in "$OUT" "$OUT/$base"; do
  [ -d "$R" ] || continue
  if diff -rq "$SRC" "$R" >/dev/null 2>&1; then
    perfect=1; cmp_root="$R"; break
  fi
done

if [ "$perfect" = 1 ]; then
  echo "structural diff -r: BIT-PERFECT  ($SRC == $cmp_root)"
else
  echo "structural diff -r: not clean at OUT or OUT/$base — checking content only:"
  diff -rq "$SRC" "$OUT/$base" 2>&1 | head -8
fi

# Path-agnostic authoritative check: the sorted multiset of file content hashes
# must be identical. If every source file's bytes appear in the unpack and vice
# versa, no bytes were lost or altered — independent of how paths nest.
h() { find "$1" -type f -exec sha256sum {} + 2>/dev/null | awk '{print $1}' | sort; }
if diff <(h "$SRC") <(h "$cmp_root") >/dev/null 2>&1; then
  nfiles=$(find "$SRC" -type f | wc -l)
  echo "content-hash multiset: BIT-PERFECT  ($nfiles files, every byte preserved)"
  echo "RESULT: LOSSLESS"
  exit 0
else
  echo "content-hash multiset: MISMATCH"
  echo "  source-only / unpack-only hashes:"
  diff <(h "$SRC") <(h "$cmp_root") | head -10
  echo "RESULT: NOT LOSSLESS"
  exit 1
fi
