#!/usr/bin/env bash
# Extract stock boot / vendor_boot images from a full OTA zip (payload.bin).
# Keeps known-good images for fastboot rollback if a custom kernel fails to boot.
#
# Requires: unzip, and payload-dumper-go
#   install payload-dumper-go:  go install github.com/ssut/payload-dumper-go@latest
#   (ensure $HOME/go/bin is on PATH, or it is on the default PATH)
#
# Usage:
#   bash extract_stock_img.sh "<rom.zip>" [out_dir] [-p boot] [-p vendor_boot]
set -euo pipefail

ZIP="${1:-}"
OUT="${2:-./stock-imgs}"
if [ -z "$ZIP" ]; then
  echo "Usage: $0 <rom.zip> [out_dir] [-p partition ...]"
  exit 1
fi
shift 2 2>/dev/null || true

PARTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -p) PARTS+=("$2"); shift 2 ;;
    *) shift ;;
  esac
done
[ ${#PARTS[@]} -eq 0 ] && PARTS=(boot vendor_boot)

[ -f "$ZIP" ] || { echo "ERROR: zip not found: $ZIP"; exit 1; }
mkdir -p "$OUT"

# locate payload-dumper-go
if command -v payload-dumper-go >/dev/null 2>&1; then
  DUMPER="payload-dumper-go"
elif [ -x "$HOME/go/bin/payload-dumper-go" ]; then
  DUMPER="$HOME/go/bin/payload-dumper-go"
else
  echo "ERROR: payload-dumper-go not found. Install with:"
  echo "    go install github.com/ssut/payload-dumper-go@latest"
  echo "and ensure \$HOME/go/bin is on PATH."
  exit 1
fi

PAYLOAD=$(mktemp -d)
trap 'rm -rf "$PAYLOAD"' EXIT

echo "==> unzip payload.bin from $ZIP"
unzip -o "$ZIP" payload.bin -d "$PAYLOAD" >/dev/null 2>&1 \
  || { echo "ERROR: payload.bin not found in $ZIP (not a full OTA zip?)"; exit 1; }

for p in "${PARTS[@]}"; do
  echo "==> extract $p"
  "$DUMPER" -p "$p" -o "$OUT" "$PAYLOAD/payload.bin" >/dev/null 2>&1 \
    && echo "    -> $OUT/$p.img" \
    || echo "    (warn) failed to extract $p"
done

echo "Done. Images in: $OUT"
ls -la "$OUT" 2>/dev/null
