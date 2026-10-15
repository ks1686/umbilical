#!/usr/bin/env bash
# Download the pinned Sparkle 2.9.6 tools and expose bin/sign_update.
# The checksum is the Sparkle Swift package checksum for the same zip.
set -euo pipefail

dest="${1:-}"
if [[ -z "${dest}" ]]; then
  echo "usage: scripts/release/fetch-sparkle-tools.sh DEST_DIR" >&2
  exit 2
fi

url="https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-for-Swift-Package-Manager.zip"
expected="8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"
work="$(mktemp -d)"
cleanup() {
  rm -rf "${work}"
}
trap cleanup EXIT

curl --fail --silent --show-error --location --retry 3 \
  --output "${work}/sparkle.zip" \
  "${url}"

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${work}/sparkle.zip" | awk '{ print $1 }')"
else
  actual="$(shasum -a 256 "${work}/sparkle.zip" | awk '{ print $1 }')"
fi
if [[ "${actual}" != "${expected}" ]]; then
  echo "Sparkle tools checksum mismatch" >&2
  exit 1
fi

rm -rf "${dest}"
mkdir -p "${dest}"
unzip -q "${work}/sparkle.zip" -d "${dest}"
chmod 755 "${dest}/bin/sign_update"
test -x "${dest}/bin/sign_update"
