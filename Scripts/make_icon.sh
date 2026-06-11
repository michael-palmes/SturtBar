#!/usr/bin/env bash
# make_icon.sh — compile Resources/AppIcon.icns from the committed master PNG.
#
# Source of truth: Resources/AppIcon-1024.png (the SturtBar lighthouse, the Cape
# Willoughby tower on warm paper per BRAND.md §4.4). Re-run this after replacing
# that PNG. Pipeline: sips scales the iconset sizes -> iconutil compiles .icns.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$ROOT/Resources/AppIcon-1024.png"
OUT="$ROOT/Resources/AppIcon.icns"
WORK_DIR="$ROOT/.build/icon"
ICONSET="$WORK_DIR/AppIcon.iconset"

[[ -f "$SRC" ]] || { echo "ERROR: master icon missing at $SRC" >&2; exit 1; }
dims=$(sips -g pixelWidth -g pixelHeight "$SRC" 2>/dev/null)
grep -q "pixelWidth: 1024" <<<"$dims" && grep -q "pixelHeight: 1024" <<<"$dims" \
  || { echo "ERROR: $SRC must be exactly 1024x1024 (got: $dims)" >&2; exit 1; }

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z "$sz" "$sz" "$SRC" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sips -z "$((sz * 2))" "$((sz * 2))" "$SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "Created $OUT from $SRC"
