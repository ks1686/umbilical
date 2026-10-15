#!/bin/sh
# Copy the pinned yt-dlp into Contents/Helpers when helpers/bin/yt-dlp exists.
# A missing binary is success so a local build can proceed without the helper.
# When the binary is present, its SHA-256 must match helpers/yt-dlp.lock.
# This phase runs before Xcode signs umbilical.app. Sign the helper first.
#
# yt-dlp_macos is a PyInstaller binary. It unpacks a Python runtime at launch.
# Hardened runtime rejects that unless the helper itself has:
#   com.apple.security.cs.disable-library-validation
#   com.apple.security.cs.allow-unsigned-executable-memory
#   com.apple.security.cs.allow-jit
# Those keys are not on the app. Repo Guard should review them before M5.
#
# M5 sets YT_DLP_CODESIGN_IDENTITY to the Developer ID. Ad hoc until then.
# M5 also adds --timestamp. Ad hoc signatures cannot use a secure timestamp,
# so this script does not pass --timestamp.
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
codesign --force --sign "${identity}" -o runtime \
  --entitlements "${entitlements}" \
  "${dest_dir}/yt-dlp"
