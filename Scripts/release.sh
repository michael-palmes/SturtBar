#!/usr/bin/env bash
# release.sh — cut a draft GitHub release of SturtBar.
#
# Flow: guards (clean tree, untagged version, tests green) -> arm64 package +
# Developer ID sign + notarize + staple (sign-and-notarize.sh) -> zip app + dSYM
# -> `gh release create v<version> --draft` with generated notes.
#
# Required env (see Scripts/sign-and-notarize.sh for the notary modes):
#   STURTBAR_SIGNING_IDENTITY                        Developer ID Application cert
#   STURTBAR_NOTARY_PROFILE                          or the KEY_ID/ISSUER/KEY_* trio
# Also requires an authenticated `gh` CLI (gh auth status).
#
# Version bump: edit version.env (MARKETING_VERSION + BUILD_NUMBER) first; the
# script refuses to reuse an already-tagged version.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
# shellcheck source=/dev/null
source "$ROOT/version.env"

APP_BUNDLE="$ROOT/dist/SturtBar.app"
TAG="v${MARKETING_VERSION}"
APP_DMG="$ROOT/dist/SturtBar-${MARKETING_VERSION}.dmg"
APP_ZIP="$ROOT/dist/SturtBar-${MARKETING_VERSION}.zip"
DSYM_ZIP="$ROOT/dist/SturtBar-${MARKETING_VERSION}.dSYM.zip"
# Derive the dSYM path from the same arm64 release build sign-and-notarize.sh produces
# (single-arch builds live under .build/<triple>/release, not .build/apple/Products).
DSYM_PATH="$(swift build -c release --arch arm64 --show-bin-path)/SturtBar.dSYM"

# --- Guards ------------------------------------------------------------------
command -v gh >/dev/null || { echo "ERROR: gh CLI not installed." >&2; exit 1; }

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree is dirty; commit or stash before releasing." >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "ERROR: tag $TAG already exists — bump MARKETING_VERSION in version.env." >&2
  exit 1
fi

echo "==> Running tests (release guard)"
swift test -q

# --- Build, sign, notarize (app + DMG) ------------------------------------------
"$ROOT/Scripts/sign-and-notarize.sh"
[[ -f "$APP_DMG" ]] || { echo "ERROR: expected DMG missing at $APP_DMG" >&2; exit 1; }

# --- Artifacts ----------------------------------------------------------------
echo "==> Zipping artifacts"
rm -f "$APP_ZIP" "$DSYM_ZIP"
/usr/bin/ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"

if [[ -d "$DSYM_PATH" ]]; then
  /usr/bin/ditto --norsrc -c -k --keepParent "$DSYM_PATH" "$DSYM_ZIP"
else
  echo "WARN: dSYM missing at $DSYM_PATH; skipping dSYM artifact." >&2
fi

# --- Release notes + draft release ---------------------------------------------
NOTES_FILE=$(mktemp "${TMPDIR:-/tmp}/sturtbar-release-notes.XXXXXX")
trap 'rm -f "$NOTES_FILE"' EXIT
PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
{
  echo "## SturtBar ${MARKETING_VERSION} (build ${BUILD_NUMBER})"
  echo ""
  if [[ -n "$PREV_TAG" ]]; then
    echo "Changes since ${PREV_TAG}:"
    git log --pretty='- %s' "${PREV_TAG}..HEAD"
  else
    echo "Changes:"
    git log --pretty='- %s' --max-count=30
  fi
} > "$NOTES_FILE"

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "SturtBar ${MARKETING_VERSION}"
git push origin "$TAG"

echo "==> Creating draft GitHub release $TAG"
ASSETS=("$APP_DMG" "$APP_ZIP") # DMG first: the human installer
[[ -f "$DSYM_ZIP" ]] && ASSETS+=("$DSYM_ZIP")
gh release create "$TAG" "${ASSETS[@]}" \
  --draft \
  --title "SturtBar ${MARKETING_VERSION}" \
  --notes-file "$NOTES_FILE"

echo "Done: draft release $TAG created. Review and publish on GitHub."
