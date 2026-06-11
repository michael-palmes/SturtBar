#!/usr/bin/env bash
# lint.sh — SwiftFormat + SwiftLint against the SturtBar tree (see .swiftformat /
# .swiftlint.yml for paths; legacy CodexBar dirs are excluded until Phase 6 deletes
# them). Degrades gracefully (warn + exit 0) when the pinned tools cannot be
# installed, e.g. offline sandboxes — CI enforces via Scripts/install_lint_tools.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${ROOT_DIR}/.build/lint-tools/bin"
SWIFTFORMAT="${BIN_DIR}/swiftformat"
SWIFTLINT="${BIN_DIR}/swiftlint"

ensure_tools() {
  # Installer is idempotent and pins versions; tolerate failure (offline) and
  # fall back to PATH tools when present.
  if "${ROOT_DIR}/Scripts/install_lint_tools.sh"; then
    return 0
  fi
  if command -v swiftformat >/dev/null 2>&1 && command -v swiftlint >/dev/null 2>&1; then
    echo "WARN: pinned lint tools unavailable; falling back to PATH swiftformat/swiftlint." >&2
    SWIFTFORMAT="swiftformat"
    SWIFTLINT="swiftlint"
    return 0
  fi
  echo "SKIPPED: lint tools unavailable (install failed, none on PATH). Code is NOT linted." >&2
  exit 0
}

cmd="${1:-lint}"

case "$cmd" in
  lint)
    ensure_tools
    "$SWIFTFORMAT" Sources Tests --lint
    "$SWIFTLINT" --strict --quiet
    ;;
  format)
    ensure_tools
    "$SWIFTFORMAT" Sources Tests
    ;;
  *)
    printf 'Usage: %s [lint|format]\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac
