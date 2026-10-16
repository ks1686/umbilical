#!/usr/bin/env bash
# Sign umbilical.app from the inside out.
# Identity "-" is ad hoc and is not timestamped.
# Any other identity is Developer ID and gets a secure timestamp.
# yt-dlp is signed with helpers/yt-dlp.entitlements and no other entitlement file.
# keychain-access-groups is applied only to the app, and only for Developer ID,
# where a provisioning profile authorizes TEAMID.me.peapod.umbilical.
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
debug_ents="${root}/App/umbilical-debug.entitlements"
tools="${root}/scripts/release/release_tools.py"

for file in "${release_ents}" "${ytdlp_ents}" "${extension_ents}" "${debug_ents}"; do
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
if grep -q 'keychain-access-groups' "${ytdlp_ents}" "${extension_ents}" "${debug_ents}"; then
  echo "keychain-access-groups is only on the app release entitlements" >&2
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
app_ents="$(mktemp)"
signed_ents="$(mktemp)"
profile_plist="$(mktemp)"
team_file="$(mktemp)"
cleanup() {
  rm -f "${empty_ents}" "${app_ents}" "${signed_ents}" "${profile_plist}" "${team_file}"
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

if [[ "${identity}" == "-" ]]; then
  rm -f "${app}/Contents/embedded.provisionprofile"
  python3 "${tools}" write-adhoc-app-entitlements \
    --template "${release_ents}" \
    --output "${app_ents}"
else
  profile="$(python3 "${tools}" resolve-provisioning-profile)"
  security cms -D -i "${profile}" >"${profile_plist}"
  python3 "${tools}" write-developer-id-app-entitlements \
    --template "${release_ents}" \
    --profile-plist "${profile_plist}" \
    --profile "${profile}" \
    --output "${app_ents}" \
    --embed "${app}/Contents/embedded.provisionprofile" \
    --team-output "${team_file}"
fi
sign "${app}" --entitlements "${app_ents}"

codesign --verify --deep --strict --verbose=2 "${app}"

require_keychain_entitlement() {
  local target="$1"
  local label="$2"
  local mode="$3"
  : >"${signed_ents}"
  codesign -d --entitlements :- "${target}" >"${signed_ents}" 2>/dev/null || true
  if [[ "${mode}" == "group" ]]; then
    python3 "${tools}" check-signed-keychain-entitlement \
      --plist "${signed_ents}" \
      --label "${label}" \
      --team "$(tr -d '[:space:]' <"${team_file}")"
  else
    python3 "${tools}" check-signed-keychain-entitlement \
      --plist "${signed_ents}" \
      --label "${label}" \
      --absent
  fi
}

if [[ "${identity}" == "-" ]]; then
  require_keychain_entitlement "${app}" "app" absent
  require_keychain_entitlement "${app}/Contents/Helpers/aria2c" "aria2c" absent
  require_keychain_entitlement "${app}/Contents/Helpers/yt-dlp" "yt-dlp" absent
  require_keychain_entitlement "${app}/Contents/Helpers/umb-watch" "umb-watch" absent
  require_keychain_entitlement "${appex[0]}" "extension" absent
  exit 0
fi

if [[ ! -f "${app}/Contents/embedded.provisionprofile" ]]; then
  echo "embedded provisioning profile is missing" >&2
  exit 1
fi
require_keychain_entitlement "${app}" "app" group
require_keychain_entitlement "${app}/Contents/Helpers/aria2c" "aria2c" absent
require_keychain_entitlement "${app}/Contents/Helpers/yt-dlp" "yt-dlp" absent
require_keychain_entitlement "${app}/Contents/Helpers/umb-watch" "umb-watch" absent
require_keychain_entitlement "${appex[0]}" "extension" absent

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
