#!/usr/bin/env bash
# Fetch the pinned yt-dlp macOS helper.
#
# The SHA-256 in helpers/yt-dlp.lock is trusted only after the GPG signature
# on the release SHA2-256SUMS file verifies against the published key in
# helpers/yt-dlp.asc. The script does not run yt-dlp and does not pass -U.
# ffmpeg is phase 2 and is not fetched here.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="${root}/helpers/yt-dlp.lock"

if [[ $# -ne 0 ]]; then
  echo "usage: scripts/fetch-helpers.sh" >&2
  exit 2
fi

for tool in curl gpg awk; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: ${tool}" >&2
    exit 1
  fi
done

lock_get() {
  local key="$1"
  awk -F= -v key="$key" '
    $1 == key {
      print substr($0, index($0, "=") + 1)
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$lock_file"
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{ print $1 }'
  else
    shasum -a 256 "$file" | awk '{ print $1 }'
  fi
}

require_url() {
  local url="$1"
  local prefix="$2"
  case "$url" in
    "${prefix}"*) ;;
    *)
      echo "refusing unexpected URL: ${url}" >&2
      exit 1
      ;;
  esac
}

download() {
  local url="$1"
  local dest="$2"
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --output "$dest" "$url"
}

version="$(lock_get version)"
asset="$(lock_get asset)"
asset_url="$(lock_get asset_url)"
lock_sha256="$(lock_get sha256 | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
sums_url="$(lock_get sums_url)"
sums_sig_url="$(lock_get sums_sig_url)"
gpg_key_rel="$(lock_get gpg_key)"
gpg_fingerprint="$(lock_get gpg_fingerprint | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"

prefix="https://github.com/yt-dlp/yt-dlp/releases/download/${version}/"
require_url "$asset_url" "$prefix"
require_url "$sums_url" "$prefix"
require_url "$sums_sig_url" "$prefix"

if [[ ! "$lock_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "sha256 in ${lock_file} is not 64 hex characters" >&2
  exit 1
fi
if [[ ! "$gpg_fingerprint" =~ ^[0-9A-F]{40}$ ]]; then
  echo "gpg_fingerprint in ${lock_file} is not 40 hex characters" >&2
  exit 1
fi

key_path="${root}/${gpg_key_rel}"
if [[ ! -f "$key_path" ]]; then
  echo "published key not found at ${key_path}" >&2
  exit 1
fi

key_fpr="$(
  gpg --batch --with-colons --show-keys "$key_path" \
    | awk -F: '$1 == "fpr" { print $10; exit }'
)"
key_fpr="$(printf '%s' "$key_fpr" | tr '[:lower:]' '[:upper:]')"
if [[ "$key_fpr" != "$gpg_fingerprint" ]]; then
  echo "vendored key fingerprint does not match the lock file" >&2
  echo "expected ${gpg_fingerprint}" >&2
  echo "actual   ${key_fpr}" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GNUPGHOME="${tmp}/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
gpg --batch --import "$key_path" >/dev/null

download "$sums_url" "${tmp}/SHA2-256SUMS"
download "$sums_sig_url" "${tmp}/SHA2-256SUMS.sig"

status_file="${tmp}/gpg-status"
gpg --batch --trust-model always --status-file "$status_file" \
  --verify "${tmp}/SHA2-256SUMS.sig" "${tmp}/SHA2-256SUMS"

if grep -Eq '^\[GNUPG:\] (BADSIG|ERRSIG|NODATA|NO_PUBKEY) ' "$status_file"; then
  echo "GPG rejected SHA2-256SUMS" >&2
  exit 1
fi
if ! grep -Eq "^\\[GNUPG:\\] GOODSIG " "$status_file"; then
  echo "GPG did not report GOODSIG for SHA2-256SUMS" >&2
  exit 1
fi
if ! grep -Eq "^\\[GNUPG:\\] VALIDSIG ${gpg_fingerprint}( |$)" "$status_file"; then
  echo "SHA2-256SUMS was not signed by ${gpg_fingerprint}" >&2
  exit 1
fi

signed_sha256="$(
  awk -v asset="$asset" '
    $2 == asset {
      print $1
      found = 1
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "${tmp}/SHA2-256SUMS" | tr '[:upper:]' '[:lower:]'
)"
if [[ "$signed_sha256" != "$lock_sha256" ]]; then
  echo "signed checksum does not match helpers/yt-dlp.lock" >&2
  echo "signed ${signed_sha256}" >&2
  echo "lock   ${lock_sha256}" >&2
  exit 1
fi

out_dir="${root}/helpers/bin"
out="${out_dir}/yt-dlp"
mkdir -p "$out_dir"
if [[ -f "$out" ]]; then
  existing="$(sha256_file "$out" | tr '[:upper:]' '[:lower:]')"
  if [[ "$existing" == "$signed_sha256" ]]; then
    chmod 0755 "$out"
    echo "yt-dlp ${version} already matches the signed checksum"
    exit 0
  fi
fi

download "$asset_url" "${tmp}/${asset}"
downloaded="$(sha256_file "${tmp}/${asset}" | tr '[:upper:]' '[:lower:]')"
if [[ "$downloaded" != "$signed_sha256" ]]; then
  echo "downloaded ${asset} does not match the signed checksum" >&2
  echo "expected ${signed_sha256}" >&2
  echo "actual   ${downloaded}" >&2
  exit 1
fi

install -m 0755 "${tmp}/${asset}" "$out"
echo "installed yt-dlp ${version} to helpers/bin/yt-dlp"
echo "self-update was not run"
