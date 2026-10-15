#!/usr/bin/env bash
# Write a sha256sum line for a file. Prints the hex digest on stdout.
set -euo pipefail

file="${1:-}"
out="${2:-}"
if [[ -z "${file}" || ! -f "${file}" ]]; then
  echo "usage: scripts/release/sha256-file.sh FILE [OUTPUT]" >&2
  exit 2
fi
if [[ -z "${out}" ]]; then
  out="${file}.sha256"
fi

if command -v sha256sum >/dev/null 2>&1; then
  hash="$(sha256sum "${file}" | awk '{ print $1 }')"
else
  hash="$(shasum -a 256 "${file}" | awk '{ print $1 }')"
fi
base="$(basename "${file}")"
printf '%s  %s\n' "${hash}" "${base}" >"${out}"
printf '%s\n' "${hash}"
