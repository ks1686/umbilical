#!/usr/bin/env bash
# Submit a signed dmg to notarytool, staple it, and assess it.
# Credentials come from a notarytool keychain profile or from local files.
# This script does not read the API key from the environment and does not
# copy the .p8 into a temp file.
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "" ]]; then
  echo "refusing to notarize from GitHub Actions" >&2
  exit 1
fi

refuse_if_set() {
  local name="$1"
  if [[ -n "${!name+x}" ]]; then
    printf '%s is set; notarization does not read signing material from the environment\n' "${name}" >&2
    exit 1
  fi
}

refuse_if_set MACOS_SIGN_P12
refuse_if_set MACOS_SIGN_PASSWORD
refuse_if_set MACOS_NOTARY_KEY
refuse_if_set SPARKLE_ED_PRIVATE_KEY

dmg="${1:-}"
if [[ -z "${dmg}" || ! -f "${dmg}" ]]; then
  echo "usage: scripts/release/notarize-dmg.sh FILE.dmg" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/../.." && pwd)"
config="${HOME}/.config/genv/notarize"
work="$(mktemp -d "${TMPDIR:-/tmp}/umbilical-notarize.XXXXXX")"
cleanup() {
  rm -rf "${work}"
}
trap cleanup EXIT

python3 "${root}/scripts/release/release_tools.py" resolve-notary \
  --config-dir "${config}" >"${work}/notary-args.txt"

notary_auth=()
while IFS= read -r line; do
  if [[ -z "${line}" ]]; then
    continue
  fi
  notary_auth+=("${line}")
done <"${work}/notary-args.txt"
if [[ "${#notary_auth[@]}" -lt 2 ]]; then
  echo "notarytool arguments are missing" >&2
  exit 1
fi

result="${work}/notarization.json"
set +e
xcrun notarytool submit "${dmg}" \
  "${notary_auth[@]}" \
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
    xcrun notarytool log "${submission}" "${notary_auth[@]}" || true
  fi
  exit 1
fi

xcrun stapler staple "${dmg}"
xcrun stapler validate "${dmg}"
spctl --assess --verbose=4 --type open --context context:primary-signature "${dmg}"
