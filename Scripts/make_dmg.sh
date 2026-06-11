#!/usr/bin/env bash
# make_dmg.sh — build dist/SturtBar-<version>.dmg from dist/SturtBar.app + chart art.
#
# Self-contained: system tools only (hdiutil, tiffutil, osascript, SetFile, sips,
# codesign). Inspired by create-dmg, but no third-party dependency. NO notarisation
# (sign-and-notarize.sh owns that). The styled layout drags SturtBar onto an
# Applications shortcut over the Sturt Light chart background (Resources/dmg/).
#
# REQUIRES a logged-in GUI session: the Finder/AppleScript styling cannot run
# headless or in CI. The first run prompts once to let the terminal control Finder.
#
# Env:
#   STURTBAR_SIGNING_IDENTITY   optional. If set, codesign the final .dmg with it.
#                               If unset, a local unsigned preview DMG is produced.
#
# Output: dist/SturtBar-<version>.dmg
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
# shellcheck source=/dev/null
source "$ROOT/version.env"

VOL_NAME="SturtBar"
APP_BUNDLE="$ROOT/dist/SturtBar.app"
BG_1X="$ROOT/Resources/dmg/dmg_bg.png"
BG_2X="$ROOT/Resources/dmg/dmg_bg@2x.png"
ICNS="$ROOT/Resources/AppIcon.icns"
WORK="$ROOT/.build/dmg"
STAGE="$WORK/stage"
TMP_DMG="$WORK/SturtBar-rw.dmg"
FINAL="$ROOT/dist/SturtBar-${MARKETING_VERSION}.dmg"

DEV=""
cleanup() {
  [[ -n "$DEV" ]] && hdiutil detach "$DEV" -force >/dev/null 2>&1 || true
  rm -rf "$STAGE"
}
trap cleanup EXIT

# --- Preconditions -----------------------------------------------------------
[[ -d "$APP_BUNDLE" ]] || { echo "ERROR: $APP_BUNDLE missing — run package_app.sh / sign-and-notarize.sh first." >&2; exit 1; }
[[ -f "$BG_1X" && -f "$BG_2X" ]] || { echo "ERROR: DMG background art missing in Resources/dmg/." >&2; exit 1; }
[[ -f "$ICNS" ]] || { echo "ERROR: $ICNS missing — run make_icon.sh." >&2; exit 1; }
check_dims() {
  local f=$1 w=$2 h=$3 dims
  dims=$(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null)
  grep -q "pixelWidth: $w" <<<"$dims" && grep -q "pixelHeight: $h" <<<"$dims" \
    || { echo "ERROR: $f must be ${w}x${h} (got: $dims)." >&2; exit 1; }
}
check_dims "$BG_1X" 660 400
check_dims "$BG_2X" 1320 800

# --- Pre-flight: detach a stray volume from a crashed prior run ---------------
if [[ -d "/Volumes/$VOL_NAME" ]]; then
  STRAY=$(hdiutil info | awk -v vol="/Volumes/$VOL_NAME" '
    /^\/dev\// { dev=$1 }
    $0 ~ vol  { print dev; exit }')
  [[ -n "${STRAY:-}" ]] && hdiutil detach "$STRAY" -force >/dev/null 2>&1 || true
fi

# --- Multi-resolution background TIFF (1x first → Finder picks the Retina rep) -
rm -rf "$WORK"
mkdir -p "$STAGE/.background"
tiffutil -cathidpicheck "$BG_1X" "$BG_2X" -out "$STAGE/.background/background.tiff"

# --- Stage the read-write image contents -------------------------------------
# cp -R preserves the already-signed/stapled app bundle (do NOT xattr/codesign it here).
cp -R "$APP_BUNDLE" "$STAGE/SturtBar.app"
ln -s /Applications "$STAGE/Applications"
cp "$ICNS" "$STAGE/.VolumeIcon.icns"

rm -f "$TMP_DMG"
hdiutil create -srcfolder "$STAGE" -volname "$VOL_NAME" -fs HFS+ -format UDRW -ov "$TMP_DMG" >/dev/null

# --- Attach ------------------------------------------------------------------
# Mount at the default /Volumes/<volname> (NOT -mountrandom): Finder addresses the
# disk by its volume name in `tell disk "SturtBar"`, so a random mount folder makes
# the styling fail with -1728. NOT -nobrowse either: Finder must see the volume.
# The pre-flight detach above clears any stale /Volumes/SturtBar before we mount.
ATTACH=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG")
DEV=$(awk 'NR==1 {print $1}' <<<"$ATTACH")
MOUNT=$(grep -Eo '/Volumes/.*$' <<<"$ATTACH" | tail -1)
[[ -n "$DEV" && -d "$MOUNT" ]] || { echo "ERROR: failed to attach $TMP_DMG." >&2; exit 1; }
SetFile -a C "$MOUNT" # honour the custom .VolumeIcon.icns

# --- Finder styling (GUI-only) ------------------------------------------------
# Window bounds {l,t,r,b}: 660 wide, 428 tall (the 400pt chart + ~28pt title bar)
# shows the full background without clipping the bottom caption. The brief centres
# the icons at (180,170)/(480,170); Finder's icon origin sits ~3pt below the chart
# origin here, so we set y=167 (empirically tuned to land the icon centres on the
# chart's marked circles to within ~0.5pt on macOS 26). Re-measure if the chart art
# or the OS title-bar height changes.
cat > "$WORK/style.applescript" <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set viewOpts to the icon view options of container window
    set arrangement of viewOpts to not arranged
    set icon size of viewOpts to 128
    set text size of viewOpts to 12
    set background picture of viewOpts to file ".background:background.tiff"
    set position of item "SturtBar.app" of container window to {180, 167}
    set position of item "Applications" of container window to {480, 167}
    set position of item ".background" of container window to {999, 999}
    set position of item ".VolumeIcon.icns" of container window to {999, 999}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT

# Finder can take a moment to register a freshly attached volume (the -1728 race);
# settle, then retry the styling a few times.
sleep 4
styled=0
for attempt in 1 2 3 4; do
  if osascript "$WORK/style.applescript" >/dev/null 2>&1; then styled=1; break; fi
  echo "  (Finder styling attempt $attempt did not take; retrying)" >&2
  sleep 3
done
if [[ "$styled" != "1" ]]; then
  echo "ERROR: Finder styling failed. If macOS asked to let the terminal control Finder," >&2
  echo "allow it (System Settings → Privacy & Security → Automation) and re-run 'make dmg'." >&2
  exit 1
fi

# --- Let Finder persist the layout, then detach ------------------------------
for _ in $(seq 1 20); do
  [[ -f "$MOUNT/.DS_Store" ]] && break
  sleep 1
done
sync
rm -rf "$MOUNT/.fseventsd" 2>/dev/null || true # Finder leaves this on the volume; keep the image clean
for _ in $(seq 1 5); do
  hdiutil detach "$DEV" >/dev/null 2>&1 && { DEV=""; break; }
  sleep 2
  hdiutil detach "$DEV" -force >/dev/null 2>&1 && { DEV=""; break; }
  sleep 2
done
[[ -z "$DEV" ]] || { echo "ERROR: could not detach $TMP_DMG." >&2; exit 1; }

# --- Compress to the final read-only image -----------------------------------
mkdir -p "$ROOT/dist"
rm -f "$FINAL"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL" >/dev/null

# --- Optional Developer ID signature -----------------------------------------
if [[ -n "${STURTBAR_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$STURTBAR_SIGNING_IDENTITY" "$FINAL"
  codesign --verify --verbose=2 "$FINAL"
  echo "Created $FINAL (signed: $STURTBAR_SIGNING_IDENTITY)"
else
  echo "Created $FINAL (unsigned preview — set STURTBAR_SIGNING_IDENTITY to sign + notarise)"
fi
