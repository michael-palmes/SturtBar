#!/usr/bin/env bash
# setup_dev_signing.sh — create a STABLE local code-signing identity for dev builds.
#
# Why: ad-hoc signatures change on every rebuild, so macOS keychain ACLs ("Always
# Allow") never stick and credential reads stall/re-prompt. A stable identity gives
# the app a stable designated requirement; grant access once and rebuilds keep it.
#
# What it does (idempotent):
#   1. If a valid "SturtBar Development" identity already exists -> done.
#   2. Generates a self-signed code-signing cert + key (openssl) and imports them
#      into a dedicated keychain (~/Library/Keychains/sturtbar-dev.keychain-db,
#      empty password, no auto-lock) added to the user search list. The dedicated
#      keychain lets us set the key partition list non-interactively, which the
#      login keychain would not allow without your macOS password.
#   3. Registers user trust for code signing (security add-trusted-cert) — macOS
#      shows ONE auth dialog for this (your login password). Skipped when run
#      non-interactively; rerun interactively to finish. Until trusted, codesign
#      cannot use the identity and dev-mode packaging fails with instructions.
#      (Why not an Apple Development cert? macOS 26 AMFI kills team-ID-signed
#      binaries that have no provisioning profile; self-signed certs have no
#      team ID and execute like local ad-hoc builds — but with a STABLE identity.)
#
# Remove with: security delete-keychain sturtbar-dev.keychain
set -euo pipefail

CERT_NAME="SturtBar Development"
KEYCHAIN="sturtbar-dev.keychain"
KEYCHAIN_DB="$HOME/Library/Keychains/sturtbar-dev.keychain-db"

if security find-identity -p codesigning -v 2>/dev/null | grep -qF "\"$CERT_NAME\""; then
  echo "OK: '$CERT_NAME' is already a valid code-signing identity."
  exit 0
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sturtbar-dev-signing.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

ensure_keychain() {
  if [[ ! -f "$KEYCHAIN_DB" ]]; then
    echo "==> Creating dedicated keychain $KEYCHAIN"
    security create-keychain -p "" "$KEYCHAIN"
  fi
  security set-keychain-settings "$KEYCHAIN" # no auto-lock, no timeout
  security unlock-keychain -p "" "$KEYCHAIN"
  # Append to the user keychain search list (list-keychains -s REPLACES the list).
  local current
  current=$(security list-keychains -d user | sed 's/^ *"//; s/"$//')
  if ! grep -qxF "$KEYCHAIN_DB" <<<"$current"; then
    echo "==> Adding $KEYCHAIN to the keychain search list"
    # shellcheck disable=SC2086 # word-splitting of keychain paths is intended
    security list-keychains -d user -s $current "$KEYCHAIN_DB"
  fi
}

create_identity() {
  if security find-certificate -c "$CERT_NAME" "$KEYCHAIN_DB" >/dev/null 2>&1; then
    echo "==> Certificate already present in $KEYCHAIN (trust may still be missing)"
    return 0
  fi
  echo "==> Generating self-signed certificate '$CERT_NAME' (10-year validity)"
  cat > "$TMP_DIR/cert.cnf" <<EOF
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[ req_distinguished_name ]
CN = $CERT_NAME
O = SturtBar local development

[ v3_req ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP_DIR/dev.key" -out "$TMP_DIR/dev.crt" -config "$TMP_DIR/cert.cnf" 2>/dev/null
  # OpenSSL 3 defaults to PKCS12 algorithms the macOS Security framework rejects
  # ("MAC verification failed"); -legacy fixes that. LibreSSL has no such flag.
  openssl pkcs12 -export -legacy -out "$TMP_DIR/dev.p12" -inkey "$TMP_DIR/dev.key" \
    -in "$TMP_DIR/dev.crt" -passout pass:sturtbar 2>/dev/null \
    || openssl pkcs12 -export -out "$TMP_DIR/dev.p12" -inkey "$TMP_DIR/dev.key" \
      -in "$TMP_DIR/dev.crt" -passout pass:sturtbar 2>/dev/null
  security import "$TMP_DIR/dev.p12" -k "$KEYCHAIN_DB" -P sturtbar \
    -T /usr/bin/codesign -A
  # Let Apple tools (codesign) use the key without a SecurityAgent prompt.
  security set-key-partition-list -S "apple-tool:,apple:,codesign:" -s -k "" \
    "$KEYCHAIN_DB" >/dev/null
  cp "$TMP_DIR/dev.crt" "$TMP_DIR/trust.crt"
}

register_trust() {
  # Trust registration is the only step macOS gates behind an auth dialog.
  if [[ ! -t 0 || "${STURTBAR_SETUP_SKIP_TRUST:-0}" == "1" ]]; then
    echo ""
    echo "SKIPPED trust registration (non-interactive or STURTBAR_SETUP_SKIP_TRUST=1)."
    echo "codesign cannot use the identity until it is trusted. To finish, rerun"
    echo "this script from a terminal, or run:"
    echo ""
    echo "    security add-trusted-cert -p codeSign -k \"$KEYCHAIN_DB\" <(security find-certificate -c \"$CERT_NAME\" -p \"$KEYCHAIN_DB\")"
    echo ""
    return 0
  fi
  echo "==> Registering code-signing trust (macOS will ask for your password ONCE)"
  if [[ ! -f "$TMP_DIR/trust.crt" ]]; then
    security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN_DB" > "$TMP_DIR/trust.crt"
  fi
  security add-trusted-cert -p codeSign -k "$KEYCHAIN_DB" "$TMP_DIR/trust.crt"
}

ensure_keychain
create_identity
register_trust

echo ""
if security find-identity -p codesigning -v 2>/dev/null | grep -qF "\"$CERT_NAME\""; then
  echo "DONE: '$CERT_NAME' is ready. Package with: STURTBAR_SIGNING=dev Scripts/package_app.sh"
else
  echo "PENDING: certificate created but not yet trusted (see message above)."
  echo "Dev-mode packaging will fail until the one-time trust step is completed."
fi
