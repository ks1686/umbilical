#!/bin/sh
# Feed tampered checksums, a bad signature, and a wrong tarball hash to the
# helper scripts. Each rejection must exit non-zero. Valid inputs must pass.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
fixtures=$(mktemp -d)
trap 'rm -rf "$fixtures"' EXIT
"$root/scripts/ci/prepare-helper-fixtures.sh" "$fixtures"

echo "valid signature is accepted"
"$root/scripts/verify-signed-sums.sh" \
  "$fixtures/SHA2-256SUMS" \
  "$fixtures/SHA2-256SUMS.sig" \
  "$fixtures/key.asc"

echo "valid tarball hash is accepted"
"$root/scripts/verify-tarball-hash.sh" \
  "$fixtures/payload.bin" \
  "$fixtures/payload.sha256"

echo "tampered SHA2-256SUMS is rejected"
if "$root/scripts/verify-signed-sums.sh" \
  "$fixtures/SHA2-256SUMS.tampered" \
  "$fixtures/SHA2-256SUMS.sig" \
  "$fixtures/key.asc"
then
  echo "tampered SHA2-256SUMS was accepted" >&2
  exit 1
fi

echo "bad signature is rejected"
if "$root/scripts/verify-signed-sums.sh" \
  "$fixtures/SHA2-256SUMS" \
  "$fixtures/SHA2-256SUMS.sig.bad" \
  "$fixtures/key.asc"
then
  echo "bad signature was accepted" >&2
  exit 1
fi

echo "wrong tarball hash is rejected"
wrong=$(cat "$fixtures/payload.sha256.wrong")
if "$root/scripts/verify-tarball-hash.sh" "$fixtures/payload.bin" "$wrong"; then
  echo "wrong tarball hash was accepted" >&2
  exit 1
fi
