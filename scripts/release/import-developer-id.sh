#!/usr/bin/env bash
# Import MACOS_SIGN_P12 into a temporary keychain.
# Writes the Developer ID Application identity to RUNNER_TEMP/signing-identity.txt.
# Does not print the .p12 or its password.
set -euo pipefail

keychain="${1:-}"
if [[ -z "${keychain}" ]]; then
  echo "usage: scripts/release/import-developer-id.sh KEYCHAIN_PATH" >&2
  exit 2
fi
if [[ -z "${MACOS_SIGN_P12:-}" || -z "${MACOS_SIGN_PASSWORD:-}" ]]; then
  echo "MACOS_SIGN_P12 or MACOS_SIGN_PASSWORD is empty" >&2
  exit 1
fi
if [[ -z "${RUNNER_TEMP:-}" ]]; then
  echo "RUNNER_TEMP is empty" >&2
  exit 1
fi

p12="${RUNNER_TEMP}/developer-id.p12"
identity_file="${RUNNER_TEMP}/signing-identity.txt"
password="$(openssl rand -base64 32 | tr -d '\n')"

cleanup_p12() {
  rm -f "${p12}"
}
trap cleanup_p12 EXIT

umask 077
P12_OUT="${p12}" python3 - <<'PY'
import base64
import os
import pathlib
import sys

raw = os.environ.get("MACOS_SIGN_P12", "")
compact = "".join(raw.split())
try:
    data = base64.b64decode(compact, validate=True)
except Exception:
    sys.exit("MACOS_SIGN_P12 is not valid base64")
if not data:
    sys.exit("MACOS_SIGN_P12 decoded to an empty file")
pathlib.Path(os.environ["P12_OUT"]).write_bytes(data)
PY

security create-keychain -p "${password}" "${keychain}"
security set-keychain-settings -lut 21600 "${keychain}"
security unlock-keychain -p "${password}" "${keychain}"
security import "${p12}" \
  -k "${keychain}" \
  -P "${MACOS_SIGN_PASSWORD}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  -f pkcs12
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "${password}" \
  "${keychain}" >/dev/null
security list-keychains -d user -s "${keychain}"
security default-keychain -s "${keychain}"

identities="$(
  security find-identity -v -p codesigning "${keychain}" \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p'
)"
count="$(printf '%s\n' "${identities}" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
if [[ "${count}" != "1" ]]; then
  echo "expected one Developer ID Application identity, found ${count}" >&2
  exit 1
fi
printf '%s\n' "${identities}" >"${identity_file}"
echo "imported Developer ID Application identity: ${identities}"
