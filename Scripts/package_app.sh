#!/usr/bin/env bash
# package_app.sh — build + assemble + sign "SturtBar.app" from SwiftPM (no Xcode project).
#
# Usage: package_app.sh [release|debug] [--universal]
#
# Env:
#   STURTBAR_SIGNING            adhoc (default) | dev | developer-id | none
#                               none keeps SwiftPM's linker signature so the
#                               build's execution-policy exception survives —
#                               for sandboxed/agent contexts without the
#                               Developer Tools privacy permission.
#   STURTBAR_SIGNING_IDENTITY   required for developer-id ("Developer ID Application: ...")
#   STURTBAR_DEV_IDENTITY       optional identity override for dev mode
#   ARCHES                      space-separated arch override (default "arm64";
#                               --universal expands to "arm64 x86_64")
#
# SturtBar ships Apple Silicon (arm64) only; --universal is kept as an opt-in for
# anyone who wants an Intel slice too.
#
# Output: dist/SturtBar.app
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

APP_NAME="SturtBar"
EXECUTABLE="SturtBar"
BUNDLE_ID="com.michaelpalmes.sturtbar"
COPYRIGHT="© 2026 Michael Palmes. MIT."
MIN_SYSTEM="26.0"
ENTITLEMENTS="$ROOT/Scripts/SturtBar.entitlements"
ICON_SOURCE="$ROOT/Resources/AppIcon.icns"

CONF="release"
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    release | debug) CONF="$arg" ;;
    --universal) UNIVERSAL=1 ;;
    --help | -h)
      sed -n '2,13p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$arg'" >&2
      exit 2
      ;;
  esac
done

SIGNING_MODE="${STURTBAR_SIGNING:-adhoc}"
# shellcheck source=/dev/null
source "$ROOT/version.env"

# --- Build -------------------------------------------------------------------
# arm64 only by default; --universal (or an ARCHES override) opts into more slices.
if [[ "$UNIVERSAL" == "1" ]]; then
  ARCHES="${ARCHES:-arm64 x86_64}"
else
  ARCHES="${ARCHES:-arm64}"
fi
BUILD_FLAGS=(-c "$CONF")
for arch in $ARCHES; do
  BUILD_FLAGS+=(--arch "$arch")
done

echo "==> swift build ${BUILD_FLAGS[*]}"
swift build "${BUILD_FLAGS[@]}"
BIN_DIR=$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)
BINARY="$BIN_DIR/$EXECUTABLE"
[[ -f "$BINARY" ]] || { echo "ERROR: built binary missing at $BINARY" >&2; exit 1; }
echo "==> binary archs: $(lipo -archs "$BINARY")"
for arch in $ARCHES; do
  lipo "$BINARY" -verify_arch "$arch" \
    || { echo "ERROR: build missing $arch slice" >&2; exit 1; }
done

# --- Resolve signing identity --------------------------------------------------
resolve_dev_identity() {
  # STURTBAR_DEV_IDENTITY override, else the self-signed "SturtBar Development" cert
  # (Scripts/setup_dev_signing.sh). Both are STABLE identities — the point of dev mode
  # is a designated requirement that survives rebuilds so keychain ACLs ("Always
  # Allow") keep working (ad-hoc churns). Deliberately NOT Apple Development certs:
  # on macOS 26, AMFI kills team-ID-signed binaries without a provisioning profile.
  # Emits "<sha1> <name>"; signing uses the hash because names can be ambiguous when
  # an expired duplicate of the same cert lingers (kernel then rejects the binary).
  local valid pattern line
  valid=$(security find-identity -p codesigning -v 2>/dev/null)
  for pattern in "${STURTBAR_DEV_IDENTITY:-}" "SturtBar Development"; do
    [[ -n "$pattern" ]] || continue
    line=$(grep -F "$pattern" <<<"$valid" | head -n 1)
    if [[ -n "$line" ]]; then
      sed -n 's/^ *[0-9]*) \([0-9A-Fa-f]*\) "\(.*\)"$/\1 \2/p' <<<"$line"
      return 0
    fi
  done
}

SIGN_ARGS=(--force)
case "$SIGNING_MODE" in
  none)
    SIGN_ARGS=()
    echo "==> signing: none (keeping SwiftPM linker signature + execution-policy exception)"
    ;;
  adhoc)
    SIGN_ARGS+=(--sign -)
    echo "==> signing: ad-hoc (keychain ACLs will NOT survive rebuilds; use STURTBAR_SIGNING=dev)"
    ;;
  dev)
    IDENTITY=$(resolve_dev_identity)
    if [[ -z "$IDENTITY" ]]; then
      echo "ERROR: no valid 'SturtBar Development' identity. Run Scripts/setup_dev_signing.sh" >&2
      echo "(its one-time trust step needs your macOS password), or set STURTBAR_DEV_IDENTITY." >&2
      exit 1
    fi
    SIGN_ARGS+=(--sign "${IDENTITY%% *}")
    echo "==> signing: dev identity '${IDENTITY#* }' (${IDENTITY%% *})"
    ;;
  developer-id)
    if [[ -z "${STURTBAR_SIGNING_IDENTITY:-}" ]]; then
      echo "ERROR: STURTBAR_SIGNING=developer-id requires STURTBAR_SIGNING_IDENTITY." >&2
      exit 1
    fi
    SIGN_ARGS+=(--timestamp --options runtime --entitlements "$ENTITLEMENTS" \
      --sign "$STURTBAR_SIGNING_IDENTITY")
    echo "==> signing: Developer ID '$STURTBAR_SIGNING_IDENTITY' (hardened runtime)"
    ;;
  *)
    echo "ERROR: unknown STURTBAR_SIGNING mode '$SIGNING_MODE' (adhoc|dev|developer-id|none)" >&2
    exit 1
    ;;
esac

# --- Assemble bundle -----------------------------------------------------------
STAGE="$ROOT/.build/package/$APP_NAME.app"
FINAL="$ROOT/dist/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

cp "$BINARY" "$STAGE/Contents/MacOS/$EXECUTABLE"
chmod +x "$STAGE/Contents/MacOS/$EXECUTABLE"

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$STAGE/Contents/Resources/AppIcon.icns"
else
  echo "WARN: $ICON_SOURCE missing — run Scripts/make_icon.sh (packaging without icon)" >&2
fi

BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_SYSTEM}</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>${COPYRIGHT}</string>
    <key>SturtBarBuildTimestamp</key><string>${BUILD_TIMESTAMP}</string>
    <key>SturtBarGitCommit</key><string>${GIT_COMMIT}</string>
</dict>
</plist>
PLIST

# Strip extended attributes that would break the code seal (AppleDouble files).
chmod -R u+w "$STAGE"
xattr -cr "$STAGE"
find "$STAGE" -name '._*' -delete

# --- Sign + install ------------------------------------------------------------
if [[ ${#SIGN_ARGS[@]} -gt 0 ]]; then
  codesign "${SIGN_ARGS[@]}" "$STAGE"
  codesign --verify --strict "$STAGE"
fi

mkdir -p "$ROOT/dist"
rm -rf "$FINAL"
mv "$STAGE" "$FINAL"

# Best-effort Gatekeeper execution-policy exception (same as SwiftPM does for its
# build outputs): lets the freshly signed binary launch without a first-run prompt.
# Works when the invoking terminal has the Developer Tools privacy permission;
# silently skipped otherwise (first launch then shows the one-time GK prompt).
if [[ "$SIGNING_MODE" != "developer-id" && "${STURTBAR_SKIP_POLICY_EXCEPTION:-0}" != "1" ]]; then
  swift -e "import ExecutionPolicy
import Foundation
try? EPExecutionPolicy().addException(for: URL(fileURLWithPath: CommandLine.arguments[1]))" \
    "$FINAL/Contents/MacOS/$EXECUTABLE" >/dev/null 2>&1 || true
fi

echo "Created $FINAL ($CONF, $(lipo -archs "$FINAL/Contents/MacOS/$EXECUTABLE"), ${MARKETING_VERSION} build ${BUILD_NUMBER})"
