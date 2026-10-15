#!/bin/sh
# Verify a detached signature over a SHA2-256SUMS file.
# usage: verify-signed-sums.sh SHA2-256SUMS SIGNATURE TRUSTED_PUBLIC_KEY
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: verify-signed-sums.sh SHA2-256SUMS SIGNATURE TRUSTED_PUBLIC_KEY" >&2
  exit 2
fi

sums=$1
signature=$2
key=$3

for file in "$sums" "$signature" "$key"; do
  if [ ! -f "$file" ]; then
    echo "missing file: $file" >&2
    exit 1
  fi
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
export GNUPGHOME="$work/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

if ! gpg --batch --quiet --import "$key" >/dev/null 2>"$work/import.err"; then
  echo "trusted key import failed" >&2
  exit 1
fi

if [ -f "$GNUPGHOME/pubring.kbx" ]; then
  keyring="$GNUPGHOME/pubring.kbx"
elif [ -f "$GNUPGHOME/pubring.gpg" ]; then
  keyring="$GNUPGHOME/pubring.gpg"
else
  echo "trusted keyring was not created" >&2
  exit 1
fi

if ! gpgv --keyring "$keyring" "$signature" "$sums" >/dev/null 2>"$work/verify.err"; then
  echo "signature rejected" >&2
  exit 1
fi
