#!/usr/bin/env bash
# Submit a signed dmg to notarytool, staple it, and assess it.
# Does not print the API key.
set -euo pipefail

dmg="${1:-}"
if [[ -z "${dmg}" || ! -f "${dmg}" ]]; then
  echo "usage: scripts/release/notarize-dmg.sh FILE.dmg" >&2
  exit 2
fi
if [[ -z "${MACOS_NOTARY_KEY:-}" ]]; then
  echo "MACOS_NOTARY_KEY is empty" >&2
  exit 1
fi
if [[ -z "${MACOS_NOTARY_KEY_ID:-}" ]]; then
  echo "MACOS_NOTARY_KEY_ID is empty" >&2
  exit 1
fi
if [[ -z "${MACOS_NOTARY_ISSUER_ID:-}" ]]; then
  echo "MACOS_NOTARY_ISSUER_ID is empty" >&2
  exit 1
fi
if [[ -z "${RUNNER_TEMP:-}" ]]; then
  echo "RUNNER_TEMP is empty" >&2
  exit 1
fi

p8="${RUNNER_TEMP}/AuthKey.p8"
result="${RUNNER_TEMP}/notarization.json"

cleanup() {
  rm -f "${p8}"
}
trap cleanup EXIT

umask 077
P8_OUT="${p8}" python3 - <<'PY'
import base64
import os
import pathlib
import sys

raw = os.environ.get("MACOS_NOTARY_KEY", "").strip()
if "BEGIN" in raw and "PRIVATE KEY" in raw:
    data = raw.encode("utf-8")
    if not data.endswith(b"\n"):
        data += b"\n"
else:
    compact = "".join(raw.split())
    try:
        data = base64.b64decode(compact, validate=True)
    except Exception:
        sys.exit("MACOS_NOTARY_KEY is not valid base64")
if b"PRIVATE KEY" not in data:
    sys.exit("MACOS_NOTARY_KEY is not an App Store Connect API key")
pathlib.Path(os.environ["P8_OUT"]).write_bytes(data)
PY
chmod 600 "${p8}"

set +e
xcrun notarytool submit "${dmg}" \
  --key "${p8}" \
  --key-id "${MACOS_NOTARY_KEY_ID}" \
  --issuer "${MACOS_NOTARY_ISSUER_ID}" \
  --wait \
  --timeout 30m \
  --output-format json \
  >"${result}"
status=$?
set -e

set +e
submission="$(
  python3 - "${result}" "${status}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
submit_status = int(sys.argv[2])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    sys.exit("notarytool did not return JSON")
state = payload.get("status") or ""
submission = payload.get("id") or ""
sys.stderr.write(f"notarytool status: {state or 'missing'}\n")
if submission:
    sys.stderr.write(f"notarytool submission: {submission}\n")
    sys.stdout.write(submission)
if submit_status != 0 or state != "Accepted":
    sys.exit(1)
PY
)"
py_status=$?
set -e
if [[ "${py_status}" -ne 0 ]]; then
  if [[ -n "${submission}" ]]; then
    echo "notarytool log:" >&2
    xcrun notarytool log "${submission}" \
      --key "${p8}" \
      --key-id "${MACOS_NOTARY_KEY_ID}" \
      --issuer "${MACOS_NOTARY_ISSUER_ID}" || true
  fi
  exit 1
fi

xcrun stapler staple "${dmg}"
xcrun stapler validate "${dmg}"
spctl --assess --verbose=4 --type open --context context:primary-signature "${dmg}"
