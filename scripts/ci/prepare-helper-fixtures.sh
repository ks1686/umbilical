#!/bin/sh
# Create a throwaway signing key and the good and bad helper inputs.
# usage: prepare-helper-fixtures.sh DIRECTORY
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: prepare-helper-fixtures.sh DIRECTORY" >&2
  exit 2
fi

output=$1
mkdir -p "$output"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GNUPGHOME="$work/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

gpg --batch --gen-key <<'EOF'
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: Umbilical Helper Test
Name-Email: helper-test@example.com
Expire-Date: 0
%commit
EOF

gpg --batch --export --armor > "$output/key.asc"

payload=$output/payload.bin
printf 'umbilical helper payload\n' > "$payload"
if command -v sha256sum >/dev/null 2>&1; then
  digest=$(sha256sum "$payload" | awk '{ print $1 }')
else
  digest=$(shasum -a 256 "$payload" | awk '{ print $1 }')
fi
printf '%s  payload.bin\n' "$digest" > "$output/SHA2-256SUMS"
printf '%s\n' "$digest" > "$output/payload.sha256"

gpg --batch --detach-sign --armor --output "$output/SHA2-256SUMS.sig" "$output/SHA2-256SUMS"

cp "$output/SHA2-256SUMS" "$output/SHA2-256SUMS.tampered"
printf 'tampered\n' >> "$output/SHA2-256SUMS.tampered"

# Extra text after the armor block is ignored, so change a character inside it.
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
' "$output/SHA2-256SUMS.sig" > "$output/SHA2-256SUMS.sig.bad"

first=$(printf '%s' "$digest" | cut -c1)
rest=$(printf '%s' "$digest" | cut -c2-)
if [ "$first" = "0" ]; then
  wrong="1${rest}"
else
  wrong="0${rest}"
fi
printf '%s\n' "$wrong" > "$output/payload.sha256.wrong"
