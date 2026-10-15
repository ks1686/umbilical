#!/usr/bin/env bash
# Build a dmg with hdiutil. The image contains umbilical.app and an Applications symlink.
set -euo pipefail

app="${1:-}"
output="${2:-}"
if [[ -z "${app}" || -z "${output}" || ! -d "${app}" ]]; then
  echo "usage: scripts/release/make-dmg.sh umbilical.app OUTPUT.dmg" >&2
  exit 2
fi

stage="$(mktemp -d)"
cleanup() {
  rm -rf "${stage}"
}
trap cleanup EXIT

ditto "${app}" "${stage}/umbilical.app"
ln -s /Applications "${stage}/Applications"
mkdir -p "$(dirname "${output}")"
rm -f "${output}"
hdiutil create \
  -volname umbilical \
  -srcfolder "${stage}" \
  -ov \
  -format UDZO \
  "${output}"
