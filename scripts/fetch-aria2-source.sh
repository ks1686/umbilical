#!/bin/sh
# Download the pinned aria2 source tarball and verify its SHA-256.
# usage: fetch-aria2-source.sh DESTINATION
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: fetch-aria2-source.sh DESTINATION" >&2
  exit 2
fi

destination=$1
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
url=https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0.tar.xz
expected="$root/helpers/checksums/aria2-1.37.0.tar.xz.sha256"
temporary=$(mktemp)
trap 'rm -f "$temporary"' EXIT

curl --fail --silent --show-error --location --retry 3 --output "$temporary" "$url"
"$root/scripts/verify-tarball-hash.sh" "$temporary" "$expected"
mkdir -p "$(dirname "$destination")"
mv "$temporary" "$destination"
trap - EXIT
