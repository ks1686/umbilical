#!/bin/sh
# Verify a tarball against a SHA-256 hex digest or a checksum file.
# usage: verify-tarball-hash.sh TARBALL EXPECTED_SHA256_OR_FILE
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: verify-tarball-hash.sh TARBALL EXPECTED_SHA256_OR_FILE" >&2
  exit 2
fi

tarball=$1
expected_arg=$2

if [ ! -f "$tarball" ]; then
  echo "missing tarball: $tarball" >&2
  exit 1
fi

if [ -f "$expected_arg" ]; then
  expected=$(awk 'NF { print $1; exit }' "$expected_arg")
else
  expected=$expected_arg
fi

expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
printf '%s\n' "$expected" | grep -Eq '^[0-9a-f]{64}$' || {
  echo "expected hash is not 64 hex characters" >&2
  exit 1
}

if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tarball" | awk '{ print $1 }')
else
  actual=$(shasum -a 256 "$tarball" | awk '{ print $1 }')
fi

if [ "$actual" != "$expected" ]; then
  echo "tarball hash mismatch" >&2
  exit 1
fi
