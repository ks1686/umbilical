#!/bin/sh
# Copy the pinned yt-dlp into Contents/Helpers.
# Release fails when helpers/bin/yt-dlp is missing.
# Debug warns and continues so a local Debug build can proceed without it.
# When the binary is present, its SHA-256 must match helpers/yt-dlp.lock.
# This phase runs before Xcode signs umbilical.app. Sign the helper first.
#
# yt-dlp_macos is a PyInstaller binary. It unpacks a Python runtime at launch.
# Hardened runtime rejects that unless the helper itself has:
#   com.apple.security.cs.disable-library-validation
#   com.apple.security.cs.allow-unsigned-executable-memory
#   com.apple.security.cs.allow-jit
# Those keys are only in helpers/yt-dlp.entitlements. The decision is
# recorded in docs/RELEASE.md. The app entitlements do not gain them.
#
# "-" is an ad hoc signature. The Mac release script passes the Developer ID.
# Ad hoc signatures cannot take a secure timestamp.
# The entitlements file is helpers/yt-dlp.entitlements and nothing else.
set -eu

src_root="${SRCROOT:-}"
target_build="${TARGET_BUILD_DIR:-}"
wrapper="${WRAPPER_NAME:-}"

if [ -z "${src_root}" ] || [ -z "${target_build}" ] || [ -z "${wrapper}" ]; then
  echo "copy-bundled-yt-dlp: missing Xcode build settings" >&2
  exit 1
fi

source="${src_root}/helpers/bin/yt-dlp"
dest_dir="${target_build}/${wrapper}/Contents/Helpers"
lock="${src_root}/helpers/yt-dlp.lock"
entitlements="${src_root}/helpers/yt-dlp.entitlements"

if [ ! -f "${source}" ]; then
  if [ "${CONFIGURATION:-}" = "Release" ]; then
    echo "copy-bundled-yt-dlp: missing helpers/bin/yt-dlp" >&2
    exit 1
  fi
  echo "copy-bundled-yt-dlp: warning: missing helpers/bin/yt-dlp; continuing" >&2
  exit 0
fi

if [ ! -f "${lock}" ] || [ ! -f "${entitlements}" ]; then
  echo "copy-bundled-yt-dlp: missing lock file or entitlements" >&2
  exit 1
fi

expected="$(
  awk -F= '$1 == "sha256" { print $2; found = 1; exit } END { if (!found) exit 1 }' "${lock}"
)" || {
  echo "copy-bundled-yt-dlp: lock file has no sha256" >&2
  exit 1
}
expected="$(printf '%s' "${expected}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${source}" | awk '{ print $1 }')"
else
  actual="$(shasum -a 256 "${source}" | awk '{ print $1 }')"
fi
actual="$(printf '%s' "${actual}" | tr '[:upper:]' '[:lower:]')"

if [ "${actual}" != "${expected}" ]; then
  echo "copy-bundled-yt-dlp: checksum mismatch" >&2
  exit 1
fi

mkdir -p "${dest_dir}"
cp "${source}" "${dest_dir}/yt-dlp"
chmod 755 "${dest_dir}/yt-dlp"

identity="${YT_DLP_CODESIGN_IDENTITY:--}"
if [ "${identity}" = "-" ]; then
  codesign --force --sign "${identity}" --options runtime \
    --entitlements "${entitlements}" \
    "${dest_dir}/yt-dlp"
else
  codesign --force --sign "${identity}" --options runtime --timestamp \
    --entitlements "${entitlements}" \
    "${dest_dir}/yt-dlp"
fi
