#!/usr/bin/env bash
# Build aria2 for the Linux engine tests.
# The shipping binary is scripts/build-aria2.sh on macOS. This recipe uses
# the same source tarball and SHA-256 from helpers/aria2.lock, and it also
# passes --disable-websocket.
# Usage: scripts/build-aria2-linux.sh PREFIX
set -euo pipefail

if [[ $# -ne 1 || -z "${1:-}" ]]; then
  echo "usage: scripts/build-aria2-linux.sh PREFIX" >&2
  exit 2
fi

prefix="$1"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="${root}/helpers/aria2.lock"

lock_get() {
  local key="$1"
  awk -F= -v key="$key" '
    $1 == key {
      print substr($0, index($0, "=") + 1)
      exit
    }
  ' "$lock_file"
}

sha256_file() {
  local file="$1"
  sha256sum "$file" | awk '{ print $1 }'
}

version="$(lock_get version)"
tarball_name="$(lock_get tarball_name)"
tarball_url="$(lock_get tarball_url)"
tarball_bytes="$(lock_get tarball_bytes)"
expected="$(lock_get tarball_sha256 | tr '[:upper:]' '[:lower:]')"
case "$tarball_url" in
  "https://github.com/aria2/aria2/releases/download/release-${version}/${tarball_name}") ;;
  *)
    echo "unexpected aria2 tarball URL" >&2
    exit 1
    ;;
esac
if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
  echo "tarball_sha256 in ${lock_file} is not 64 hex characters" >&2
  exit 1
fi

src_dir="${root}/helpers/src"
tarball="${src_dir}/${tarball_name}"
mkdir -p "$src_dir"
if [[ ! -f "$tarball" ]] \
  || [[ "$(sha256_file "$tarball" | tr '[:upper:]' '[:lower:]')" != "$expected" ]]; then
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --output "${tarball}.partial" "$tarball_url"
  mv "${tarball}.partial" "$tarball"
fi

actual="$(sha256_file "$tarball" | tr '[:upper:]' '[:lower:]')"
if [[ "$actual" != "$expected" ]]; then
  echo "tarball SHA-256 mismatch" >&2
  exit 1
fi
actual_bytes="$(wc -c <"$tarball" | tr -d '[:space:]')"
if [[ "$actual_bytes" != "$tarball_bytes" ]]; then
  echo "tarball size mismatch: expected ${tarball_bytes}, got ${actual_bytes}" >&2
  exit 1
fi

tree="$(mktemp -d)"
trap 'rm -rf "$tree"' EXIT
tar -xJf "$tarball" -C "$tree" --strip-components=1
cd "$tree"
./configure \
  --prefix="$prefix" \
  --disable-websocket \
  --with-openssl \
  --disable-nls
if ! grep -Eq '^WebSocket:[[:space:]]+no([[:space:]]|$)' config.log; then
  echo "WebSocket was not disabled" >&2
  exit 1
fi
jobs="$(nproc)"
make -j"$jobs"
make install
echo "installed aria2c to ${prefix}/bin/aria2c"
