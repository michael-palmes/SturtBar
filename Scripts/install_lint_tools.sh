#!/usr/bin/env bash
# install_lint_tools.sh — install pinned SwiftFormat/SwiftLint into .build/lint-tools.
# macOS-only (lint runs on macOS locally and in CI). Idempotent: exits early when
# the pinned versions are already present.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${ROOT_DIR}/.build/lint-tools/bin"

SWIFTFORMAT_VERSION="0.61.1"
SWIFTLINT_VERSION="0.63.3"
SWIFTFORMAT_SHA256="b990400779aceb7d7020796eb9ba814d4480543f671d38fc0ff48cb72f04c584"
SWIFTLINT_SHA256="fb045e85e7cb3374f42a4840b6b85a0106302afa69035c0c6f29af4a44c810b6"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Lint tooling is macOS-only."

if [[ -x "${BIN_DIR}/swiftformat" && -x "${BIN_DIR}/swiftlint" ]] \
  && [[ "$("${BIN_DIR}/swiftformat" --version 2>/dev/null || true)" == "${SWIFTFORMAT_VERSION}" ]] \
  && [[ "$("${BIN_DIR}/swiftlint" version 2>/dev/null || true)" == "${SWIFTLINT_VERSION}" ]]; then
  log "==> Lint tools already installed (${SWIFTFORMAT_VERSION}, ${SWIFTLINT_VERSION})"
  exit 0
fi

install_zip_binary() {
  local label="$1" url="$2" expected_sha="$3" binary_name="$4"
  local tmp_zip tmp_dir actual_sha extracted_path
  tmp_zip="$(mktemp -t "${label// /-}.XXXX")"
  tmp_dir="$(mktemp -d -t "${label// /-}.XXXX")"
  # shellcheck disable=SC2064 # expand tmp paths now, not at trap time
  trap "rm -rf '$tmp_zip' '$tmp_dir'" RETURN

  log "==> Downloading ${label}"
  curl -fsSL --retry 3 --retry-connrefused --retry-delay 2 -o "$tmp_zip" "$url"

  actual_sha="$(shasum -a 256 "$tmp_zip" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] \
    || fail "${label} SHA256 mismatch (expected ${expected_sha}, got ${actual_sha})"

  unzip -q "$tmp_zip" -d "$tmp_dir"
  extracted_path="$(find "$tmp_dir" -type f -name "$binary_name" | head -n 1 || true)"
  [[ -n "$extracted_path" && -f "$extracted_path" ]] \
    || fail "${label} binary '${binary_name}' not found in archive"
  install -m 0755 "$extracted_path" "${BIN_DIR}/${binary_name}"
}

mkdir -p "$BIN_DIR"
install_zip_binary "SwiftFormat ${SWIFTFORMAT_VERSION}" \
  "https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat.zip" \
  "$SWIFTFORMAT_SHA256" swiftformat
install_zip_binary "SwiftLint ${SWIFTLINT_VERSION}" \
  "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip" \
  "$SWIFTLINT_SHA256" swiftlint

log "==> Installed lint tools to ${BIN_DIR}"
"${BIN_DIR}/swiftformat" --version
"${BIN_DIR}/swiftlint" version
