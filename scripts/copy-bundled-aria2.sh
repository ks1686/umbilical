#!/bin/sh
# Copy a locally built aria2c into Contents/Helpers.
# Release fails when helpers/bin/aria2c is missing.
# Debug warns and continues so a local Debug build can proceed without it.
# When the binary is present, its Enabled Features line must not contain
# WebSocket. This phase runs before Xcode signs umbilical.app. Sign the
# helper first.
set -eu

src_root="${SRCROOT:-}"
target_build="${TARGET_BUILD_DIR:-}"
wrapper="${WRAPPER_NAME:-}"

if [ -z "${src_root}" ] || [ -z "${target_build}" ] || [ -z "${wrapper}" ]; then
  echo "copy-bundled-aria2: missing Xcode build settings" >&2
  exit 1
fi

source="${src_root}/helpers/bin/aria2c"
dest_dir="${target_build}/${wrapper}/Contents/Helpers"

if [ ! -x "${source}" ]; then
  if [ "${CONFIGURATION:-}" = "Release" ]; then
    echo "copy-bundled-aria2: missing helpers/bin/aria2c" >&2
    exit 1
  fi
  echo "copy-bundled-aria2: warning: missing helpers/bin/aria2c; continuing" >&2
  exit 0
fi

features_line="$(
  "${source}" -v | awk '/^Enabled Features/ { print; found = 1; exit } END { if (!found) exit 1 }'
)" || {
  echo "copy-bundled-aria2: no Enabled Features line from ${source}" >&2
  exit 1
}

case "${features_line}" in
  *WebSocket*)
    echo "copy-bundled-aria2: refusing WebSocket in: ${features_line}" >&2
    exit 1
    ;;
esac

mkdir -p "${dest_dir}"
cp "${source}" "${dest_dir}/aria2c"
chmod 755 "${dest_dir}/aria2c"

# "-" is an ad hoc signature. The tag workflow passes the Developer ID.
# Ad hoc signatures cannot take a secure timestamp.
identity="${ARIA2_CODESIGN_IDENTITY:--}"
if [ "${identity}" = "-" ]; then
  codesign --force --sign "${identity}" --options runtime "${dest_dir}/aria2c"
else
  codesign --force --sign "${identity}" --options runtime --timestamp "${dest_dir}/aria2c"
fi
