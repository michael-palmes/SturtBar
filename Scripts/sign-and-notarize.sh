#!/usr/bin/env bash
# sign-and-notarize.sh — Developer ID sign, notarize, and staple "SturtBar.app".
#
# Packages an arm64 release bundle (hardened runtime + timestamp via
# package_app.sh developer-id mode), submits it to Apple notarization, waits,
# staples the ticket, and Gatekeeper-verifies the result. Standalone given env.
#
# Required env:
#   STURTBAR_SIGNING_IDENTITY   "Developer ID Application: Name (TEAMID)"
# Notary credentials — exactly one mode:
#   A) STURTBAR_NOTARY_PROFILE  notarytool keychain profile name
#      (created once via: xcrun notarytool store-credentials <name> ...)
#   B) STURTBAR_NOTARY_KEY_ID + STURTBAR_NOTARY_ISSUER + STURTBAR_NOTARY_KEY_PATH
#      App Store Connect API key (.p8 file on disk)
#   C) STURTBAR_NOTARY_KEY_ID + STURTBAR_NOTARY_ISSUER + STURTBAR_NOTARY_KEY_P8
#      same, but inline key material (literal \n sequences allowed)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
# shellcheck source=/dev/null
source "$ROOT/version.env"
APP_BUNDLE="$ROOT/dist/SturtBar.app"
DMG="$ROOT/dist/SturtBar-${MARKETING_VERSION}.dmg"

if [[ -z "${STURTBAR_SIGNING_IDENTITY:-}" ]]; then
  echo "ERROR: STURTBAR_SIGNING_IDENTITY is not set." >&2
  exit 1
fi

NOTARY_ARGS=()
if [[ -n "${STURTBAR_NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$STURTBAR_NOTARY_PROFILE")
elif [[ -n "${STURTBAR_NOTARY_KEY_ID:-}" && -n "${STURTBAR_NOTARY_ISSUER:-}" ]]; then
  NOTARY_ARGS=(--key-id "$STURTBAR_NOTARY_KEY_ID" --issuer "$STURTBAR_NOTARY_ISSUER")
else
  cat >&2 <<'EOF'
ERROR: missing notary credentials. Set either:
  STURTBAR_NOTARY_PROFILE
or
  STURTBAR_NOTARY_KEY_ID + STURTBAR_NOTARY_ISSUER + (STURTBAR_NOTARY_KEY_PATH | STURTBAR_NOTARY_KEY_P8)
EOF
  exit 1
fi

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sturtbar-notarize.XXXXXX")
chmod 700 "$TEMP_DIR"
trap 'rm -rf "$TEMP_DIR"' EXIT

if [[ -z "${STURTBAR_NOTARY_PROFILE:-}" ]]; then
  if [[ -n "${STURTBAR_NOTARY_KEY_PATH:-}" ]]; then
    [[ -f "$STURTBAR_NOTARY_KEY_PATH" ]] \
      || { echo "ERROR: STURTBAR_NOTARY_KEY_PATH not found: $STURTBAR_NOTARY_KEY_PATH" >&2; exit 1; }
    NOTARY_ARGS+=(--key "$STURTBAR_NOTARY_KEY_PATH")
  elif [[ -n "${STURTBAR_NOTARY_KEY_P8:-}" ]]; then
    KEY_FILE="$TEMP_DIR/notary-key.p8"
    (umask 077 && printf '%s' "$STURTBAR_NOTARY_KEY_P8" | sed 's/\\n/\n/g' > "$KEY_FILE")
    NOTARY_ARGS+=(--key "$KEY_FILE")
  else
    echo "ERROR: set STURTBAR_NOTARY_KEY_PATH or STURTBAR_NOTARY_KEY_P8." >&2
    exit 1
  fi
fi

echo "==> Packaging arm64 release bundle (Developer ID, hardened runtime)"
STURTBAR_SIGNING=developer-id "$ROOT/Scripts/package_app.sh" release

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

NOTARIZE_ZIP="$TEMP_DIR/SturtBarNotarize.zip"
/usr/bin/ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"

echo "==> Submitting for notarization (waits for Apple)"
xcrun notarytool submit "$NOTARIZE_ZIP" "${NOTARY_ARGS[@]}" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

# Stapling rewrites bundle contents; clear any attrs that would dirty later zips.
xattr -cr "$APP_BUNDLE"
find "$APP_BUNDLE" -name '._*' -delete

echo "==> Gatekeeper assessment"
spctl -a -t exec -vv "$APP_BUNDLE"

# --- DMG installer (built from the stapled app; independently notarised) -------
echo "==> Building styled DMG installer"
"$ROOT/Scripts/make_dmg.sh" # signs the DMG (identity already in env)

echo "==> Submitting DMG for notarization (waits for Apple)"
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait

echo "==> Stapling DMG ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Gatekeeper assessment (DMG)"
spctl -a -t open --context context:primary-signature -vv "$DMG"

echo "Done: $APP_BUNDLE and $DMG are signed, notarized, and stapled."
