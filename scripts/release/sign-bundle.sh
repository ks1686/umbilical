#!/usr/bin/env bash
# Sign umbilical.app from the inside out.
# Identity "-" is ad hoc and is not timestamped.
# Any other identity is Developer ID and gets a secure timestamp.
# yt-dlp is signed with helpers/yt-dlp.entitlements and no other entitlement file.
set -euo pipefail

app="${1:-}"
identity="${2:-}"
root="${3:-}"
if [[ -z "${app}" || -z "${identity}" || -z "${root}" ]]; then
  echo "usage: scripts/release/sign-bundle.sh umbilical.app IDENTITY REPO_ROOT" >&2
  exit 2
fi
if [[ ! -d "${app}" ]]; then
  echo "app not found" >&2
  exit 1
fi

release_ents="${root}/App/umbilical.entitlements"
ytdlp_ents="${root}/helpers/yt-dlp.entitlements"
extension_ents="${root}/Extension/Extension.entitlements"

for file in "${release_ents}" "${ytdlp_ents}" "${extension_ents}"; do
  if [[ ! -f "${file}" ]]; then
    echo "missing entitlements file: ${file}" >&2
    exit 1
  fi
done

if grep -q 'com.apple.security.get-task-allow' "${release_ents}"; then
  echo "release entitlements include get-task-allow" >&2
  exit 1
fi
if grep -q 'disable-library-validation' "${release_ents}"; then
  echo "release entitlements disable library validation" >&2
  exit 1
fi

sign() {
  local target="$1"
  shift
  if [[ "${identity}" == "-" ]]; then
    codesign --force --sign "${identity}" --options runtime "$@" "${target}"
  else
    codesign --force --sign "${identity}" --options runtime --timestamp "$@" "${target}"
  fi
}

empty_ents="$(mktemp)"
cleanup() {
  rm -f "${empty_ents}"
}
trap cleanup EXIT

cat >"${empty_ents}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
EOF

preserve_sign() {
  local target="$1"
  local ents
  ents="$(mktemp)"
  if codesign -d --entitlements :- "${target}" >"${ents}" 2>/dev/null && grep -q '<dict>' "${ents}"; then
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "${ents}" >/dev/null 2>&1 || true
    sign "${target}" --preserve-metadata=identifier --entitlements "${ents}"
  else
    sign "${target}" --preserve-metadata=identifier
  fi
  rm -f "${ents}"
}

sparkle="${app}/Contents/Frameworks/Sparkle.framework"
version_b="${sparkle}/Versions/B"
if [[ ! -d "${version_b}" ]]; then
  echo "missing Sparkle.framework" >&2
  exit 1
fi

preserve_sign "${version_b}/XPCServices/Downloader.xpc"
preserve_sign "${version_b}/XPCServices/Installer.xpc"
preserve_sign "${version_b}/Updater.app"
preserve_sign "${version_b}/Autoupdate"
preserve_sign "${sparkle}"

sign "${app}/Contents/Helpers/umb-watch" --entitlements "${empty_ents}"
sign "${app}/Contents/Helpers/aria2c" --entitlements "${empty_ents}"
sign "${app}/Contents/Helpers/yt-dlp" --entitlements "${ytdlp_ents}"

shopt -s nullglob
appex=("${app}/Contents/PlugIns/"*.appex)
if [[ ${#appex[@]} -ne 1 ]]; then
  echo "expected one Safari extension" >&2
  exit 1
fi
sign "${appex[0]}" --entitlements "${extension_ents}"
sign "${app}" --entitlements "${release_ents}"

codesign --verify --deep --strict --verbose=2 "${app}"

if [[ "${identity}" == "-" ]]; then
  exit 0
fi

verify_developer_id() {
  local target="$1"
  local dump
  dump="$(codesign -dv --verbose=4 "${target}" 2>&1)" || {
    echo "codesign could not read ${target}" >&2
    exit 1
  }
  if ! printf '%s\n' "${dump}" | grep -q 'flags=.*runtime'; then
    echo "hardened runtime missing: ${target}" >&2
    exit 1
  fi
  if ! printf '%s\n' "${dump}" | grep -q 'Authority=Developer ID Application:'; then
    echo "Developer ID missing: ${target}" >&2
    exit 1
  fi
  if ! printf '%s\n' "${dump}" | grep -q 'Timestamp='; then
    echo "timestamp missing: ${target}" >&2
    exit 1
  fi
}

verify_developer_id "${app}"
verify_developer_id "${app}/Contents/Helpers/aria2c"
verify_developer_id "${app}/Contents/Helpers/yt-dlp"
verify_developer_id "${app}/Contents/Helpers/umb-watch"
verify_developer_id "${appex[0]}"
verify_developer_id "${sparkle}"
verify_developer_id "${version_b}/XPCServices/Downloader.xpc"
verify_developer_id "${version_b}/XPCServices/Installer.xpc"
verify_developer_id "${version_b}/Updater.app"
verify_developer_id "${version_b}/Autoupdate"
