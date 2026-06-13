#!/usr/bin/env bash
# compile_and_run.sh: fast dev loop. Build, package, relaunch "SturtBar.app".
#
# Usage: compile_and_run.sh [release]   (debug build by default)
# Env:   STURTBAR_SIGNING=adhoc|dev|developer-id      (default: dev when a stable
#        identity exists, else adhoc; dev keeps keychain ACLs across rebuilds)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP_BUNDLE="$ROOT/dist/SturtBar.app"
EXECUTABLE="SturtBar"
CONF="debug"

for arg in "$@"; do
  case "$arg" in
    release | debug) CONF="$arg" ;;
    --help | -h)
      echo "Usage: $(basename "$0") [release|debug]"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$arg'" >&2
      exit 2
      ;;
  esac
done

# Default to the stable dev identity when available (ad-hoc churns keychain ACLs).
SIGNING="${STURTBAR_SIGNING:-}"
if [[ -z "$SIGNING" ]]; then
  if security find-identity -p codesigning -v 2>/dev/null \
    | grep -qF '"SturtBar Development"'; then
    SIGNING="dev"
  else
    SIGNING="adhoc"
    echo "NOTE: ad-hoc signing (keychain access re-prompts every rebuild)." >&2
    echo "      Run Scripts/setup_dev_signing.sh once for a stable identity." >&2
  fi
fi

echo "==> Packaging ($CONF, signing: $SIGNING)"
STURTBAR_SIGNING="$SIGNING" "$ROOT/Scripts/package_app.sh" "$CONF"

echo "==> Stopping running instances"
pkill -x "$EXECUTABLE" 2>/dev/null || true
for _ in {1..20}; do
  pgrep -x "$EXECUTABLE" >/dev/null 2>&1 || break
  sleep 0.2
done
pkill -9 -x "$EXECUTABLE" 2>/dev/null || true

echo "==> Launching $APP_BUNDLE"
# Gatekeeper on macOS 26 blocks (and may trash!) LaunchServices launches of
# non-notarized local builds unless the invoking terminal has the Developer
# Tools privacy permission. Fall back to direct exec, which is not assessed.
if [[ "${STURTBAR_LAUNCH:-open}" != "exec" ]] && open -n "$APP_BUNDLE" 2>/dev/null; then
  :
elif [[ -x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE" ]]; then
  echo "==> open failed or skipped; launching binary directly"
  "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE" >/dev/null 2>&1 &
  disown
else
  echo "ERROR: bundle missing after launch attempt — Gatekeeper may have moved it" >&2
  echo "to the Trash. Grant your terminal Developer Tools permission (System" >&2
  echo "Settings > Privacy & Security > Developer Tools) or rerun with" >&2
  echo "STURTBAR_LAUNCH=exec, then repackage." >&2
  exit 1
fi

for _ in {1..15}; do
  if pgrep -x "$EXECUTABLE" >/dev/null 2>&1; then
    echo "OK: SturtBar is running."
    exit 0
  fi
  sleep 0.4
done
echo "ERROR: app exited immediately — check Console.app crash reports." >&2
exit 1
