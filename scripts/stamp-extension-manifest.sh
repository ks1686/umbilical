#!/bin/sh
# Write MARKETING_VERSION into the built Safari Web Extension manifest
# so it cannot drift from the app version.
set -eu

version="${MARKETING_VERSION:-}"
target_build="${TARGET_BUILD_DIR:-}"
resources_folder="${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}"
src_root="${SRCROOT:-}"

if [ -z "${version}" ] || [ -z "${target_build}" ] || [ -z "${resources_folder}" ]; then
  echo "stamp-extension-manifest: missing Xcode build settings" >&2
  exit 1
fi

manifest="${target_build}/${resources_folder}/manifest.json"
if [ ! -f "${manifest}" ]; then
  echo "stamp-extension-manifest: missing ${manifest}" >&2
  exit 1
fi

stamp_py="${src_root}/scripts/release/release_tools.py"
if [ ! -f "${stamp_py}" ]; then
  echo "stamp-extension-manifest: missing ${stamp_py}" >&2
  exit 1
fi

python3 "${stamp_py}" stamp-manifest --manifest "${manifest}" --version "${version}"
