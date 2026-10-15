#!/bin/sh
# Copy a locally built aria2c into the app bundle when it exists.
# The App CI job does not build aria2c, so a missing binary is success.
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
mkdir -p "${dest_dir}"

if [ -x "${source}" ]; then
  cp "${source}" "${dest_dir}/aria2c"
  chmod 755 "${dest_dir}/aria2c"
fi
