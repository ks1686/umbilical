#!/usr/bin/env bash
# Feed a tampered SHA2-256SUMS, a bad signature, and a wrong tarball hash to
# the helper scripts. Each rejection must exit non-zero. Valid inputs must pass.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lock_file="${root}/helpers/yt-dlp.lock"

lock_get() {
  local key="$1"
  awk -F= -v key="$key" '
    $1 == key {
      print substr($0, index($0, "=") + 1)
      exit
    }
  ' "$lock_file"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sums_url="$(lock_get sums_url)"
sig_url="$(lock_get sums_sig_url)"
case "$sums_url" in
  https://github.com/yt-dlp/yt-dlp/releases/download/*/SHA2-256SUMS) ;;
  *)
    echo "unexpected sums URL" >&2
    exit 1
    ;;
esac
case "$sig_url" in
  https://github.com/yt-dlp/yt-dlp/releases/download/*/SHA2-256SUMS.sig) ;;
  *)
    echo "unexpected signature URL" >&2
    exit 1
    ;;
esac

curl --fail --silent --show-error --location --retry 3 \
  --output "${work}/SHA2-256SUMS" "$sums_url"
curl --fail --silent --show-error --location --retry 3 \
  --output "${work}/SHA2-256SUMS.sig" "$sig_url"

echo "valid signature is accepted"
"${root}/scripts/fetch-helpers.sh" \
  --verify-sums "${work}/SHA2-256SUMS" "${work}/SHA2-256SUMS.sig"

cp "${work}/SHA2-256SUMS" "${work}/SHA2-256SUMS.tampered"
printf 'tampered\n' >>"${work}/SHA2-256SUMS.tampered"
echo "tampered SHA2-256SUMS is rejected"
if "${root}/scripts/fetch-helpers.sh" \
  --verify-sums "${work}/SHA2-256SUMS.tampered" "${work}/SHA2-256SUMS.sig"
then
  echo "tampered SHA2-256SUMS was accepted" >&2
  exit 1
fi

awk '
  /-----BEGIN PGP SIGNATURE-----/ { print; inside = 1; next }
  /-----END PGP SIGNATURE-----/ { inside = 0; print; next }
  inside && !flipped && length($0) > 8 {
    first = substr($0, 1, 1)
    replacement = (first == "A" ? "B" : "A")
    print replacement substr($0, 2)
    flipped = 1
    next
  }
  { print }
' "${work}/SHA2-256SUMS.sig" >"${work}/SHA2-256SUMS.sig.bad"

echo "bad signature is rejected"
if "${root}/scripts/fetch-helpers.sh" \
  --verify-sums "${work}/SHA2-256SUMS" "${work}/SHA2-256SUMS.sig.bad"
then
  echo "bad signature was accepted" >&2
  exit 1
fi

printf 'not the aria2 tarball\n' >"${work}/wrong.tar.xz"
echo "wrong tarball hash is rejected"
if "${root}/scripts/build-aria2.sh" --verify-file "${work}/wrong.tar.xz"; then
  echo "wrong tarball hash was accepted" >&2
  exit 1
fi

echo "valid tarball hash is accepted"
"${root}/scripts/build-aria2.sh" --verify-tarball
echo "helper rejection checks passed"
