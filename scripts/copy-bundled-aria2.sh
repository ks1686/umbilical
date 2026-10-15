#!/bin/sh
# Copy a locally built aria2c into Contents/Helpers when it exists.
# The App CI job does not build aria2c, so a missing binary is success.
# This phase runs before Xcode signs umbilical.app. Sign the helper first.
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

# M5 sets ARIA2_CODESIGN_IDENTITY to the Developer ID. Ad hoc until then.
identity="${ARIA2_CODESIGN_IDENTITY:--}"
codesign --force --sign "${identity}" -o runtime "${dest_dir}/aria2c"
