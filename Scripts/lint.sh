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

# Shell scripts break silently until a release night finds them; a bare syntax pass is
# nearly free. All Scripts/*.sh declare bash shebangs.
check_shell_syntax() {
  local failed=0
  local script
  for script in "${ROOT_DIR}"/Scripts/*.sh; do
    if ! bash -n "$script"; then
      echo "ERROR: shell syntax check failed: ${script#"${ROOT_DIR}"/}" >&2
      failed=1
    fi
  done
  return "$failed"
}

# Repository size guard: inspects INDEX blobs, so a
# mutated or deleted working copy cannot dodge it. Rejects tracked build/package artefacts
# outright and any other blob over 2 MiB unless allowlisted (the app icon assets are the
# only sanctioned large files).
check_repo_size() {
  local max_bytes=$((2 * 1024 * 1024))
  local allowlist="Resources/AppIcon.icns
Resources/AppIcon-1024.png"
  local failed=0
  local size path
  while IFS=$'\t' read -r size path; do
    [ -n "$path" ] || continue
    case "$path" in
      *.app/*|*.dSYM/*|*.xcarchive/*|*.xcresult/*|*.ipa|*.zip|*.delta|*.dmg|*.pkg|*.tar.gz|*.tgz)
        echo "ERROR: build/package artefact tracked in git: $path" >&2
        failed=1
        continue
        ;;
    esac
    if [ "$size" -gt "$max_bytes" ] && ! grep -qxF "$path" <<< "$allowlist"; then
      echo "ERROR: tracked file exceeds 2 MiB: $path ($size bytes). Allowlist it in Scripts/lint.sh only if it truly belongs in git." >&2
      failed=1
    fi
  done < <(paste -d$'\t' \
    <(git -C "$ROOT_DIR" ls-files -s | awk '{print $2}' \
        | git -C "$ROOT_DIR" cat-file --batch-check='%(objectsize)') \
    <(git -C "$ROOT_DIR" ls-files))
  return "$failed"
}

cmd="${1:-lint}"

case "$cmd" in
  lint)
    ensure_tools
    check_shell_syntax
    check_repo_size
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
