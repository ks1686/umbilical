#!/usr/bin/env bash
# Sign, notarize, and publish a vX.Y.Z tag from the signing Mac.
# The Developer ID certificate, the App Store Connect API key, and the
# Sparkle private key stay in the login Keychain and under ~/.config/genv.
# This script does not read that material from the environment.
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "" ]]; then
  echo "refusing to publish from GitHub Actions" >&2
  exit 1
fi

# ${!name+x} is set when the named variable is set, including when it is empty.
# The value is not expanded and is not printed. Bash 3.2 accepts this form.
refuse_if_set() {
  local name="$1"
  if [[ -n "${!name+x}" ]]; then
    printf '%s is set; umbilical does not read signing material from the environment\n' "${name}" >&2
    exit 1
  fi
}

refuse_if_set MACOS_SIGN_P12
refuse_if_set MACOS_SIGN_PASSWORD
refuse_if_set MACOS_NOTARY_KEY
refuse_if_set SPARKLE_ED_PRIVATE_KEY

if [[ -n "${SPARKLE_ED_KEY_FILE+x}" ]]; then
  if [[ -z "${SPARKLE_ED_KEY_FILE}" || "${SPARKLE_ED_KEY_FILE}" == "-" || "${SPARKLE_ED_KEY_FILE}" == *"PRIVATE KEY"* || "${SPARKLE_ED_KEY_FILE}" == *$'\n'* ]]; then
    echo "SPARKLE_ED_KEY_FILE is not a file path" >&2
    exit 1
  fi
fi

if [[ "$#" -ne 1 ]]; then
  echo "usage: scripts/release/publish.sh vX.Y.Z" >&2
  exit 2
fi
tag="$1"

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${root}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1" >&2
    exit 1
  fi
}

for cmd in git gh python3 codesign xcrun hdiutil security xcodegen pkg-config gpg curl unzip ditto plutil xcodebuild openssl spctl; do
  require_cmd "${cmd}"
done
if [[ ! -x /usr/libexec/PlistBuddy ]]; then
  echo "missing /usr/libexec/PlistBuddy" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "working tree is not clean" >&2
  exit 1
fi

unset GH_TOKEN
unset GITHUB_TOKEN
if ! gh auth status; then
  echo "gh is not logged in on this Mac" >&2
  exit 1
fi

origin="$(git remote get-url origin)" || exit 1
python3 scripts/release/release_tools.py assert-repo --remote "${origin}"

version="$(python3 scripts/release/release_tools.py version-from-tag --tag "${tag}")" || exit 1

if ! git fetch origin "refs/tags/${tag}:refs/tags/${tag}"; then
  echo "tag ${tag} is missing on origin, or the local tag differs" >&2
  exit 1
fi
head_sha="$(git rev-parse HEAD)" || exit 1
tag_sha="$(git rev-parse "${tag}^{commit}")" || exit 1
if [[ "${head_sha}" != "${tag_sha}" ]]; then
  echo "HEAD ${head_sha} is not ${tag} (${tag_sha})" >&2
  exit 1
fi

umask 077
scratch=""
cleanup() {
  if [[ -n "${scratch}" ]]; then
    rm -rf "${scratch}"
  fi
}
trap cleanup EXIT
scratch="$(mktemp -d "${TMPDIR:-/tmp}/umbilical-release.XXXXXX")" || exit 1
export RUNNER_TEMP="${scratch}"

login="${HOME}/Library/Keychains/login.keychain-db"
if [[ ! -f "${login}" ]]; then
  login="${HOME}/Library/Keychains/login.keychain"
fi
if [[ ! -f "${login}" ]]; then
  echo "login keychain is missing" >&2
  exit 1
fi
security unlock-keychain "${login}"
security find-identity -v -p codesigning "${login}" >"${RUNNER_TEMP}/find-identity.txt"
identity="$(
  python3 scripts/release/release_tools.py signing-identity \
    --from-file "${RUNNER_TEMP}/find-identity.txt"
)" || exit 1
if [[ -z "${identity}" ]]; then
  echo "signing identity is empty" >&2
  exit 1
fi
echo "using Developer ID identity: ${identity}"
python3 scripts/release/release_tools.py resolve-provisioning-profile >/dev/null
echo "Developer ID provisioning profile is present"

if [[ -n "${SPARKLE_ED_KEY_FILE+x}" ]]; then
  sparkle_key="${SPARKLE_ED_KEY_FILE}"
else
  sparkle_key="${HOME}/.config/genv/sparkle/umbilical.key"
fi
if [[ -z "${sparkle_key}" || "${sparkle_key}" == "-" || "${sparkle_key}" == *"PRIVATE KEY"* || "${sparkle_key}" == *$'\n'* ]]; then
  echo "Sparkle private key path is not a file path" >&2
  exit 1
fi
python3 scripts/release/release_tools.py check-sparkle-key \
  --info-plist App/Info.plist \
  --key-file "${sparkle_key}"

org_id="$(
  python3 scripts/release/release_tools.py write-licensing-xcconfig \
    --dest Config/Licensing.local.xcconfig
)" || exit 1
if [[ -z "${org_id}" ]]; then
  echo "POLAR_ORGANIZATION_ID is empty" >&2
  exit 1
fi
export POLAR_ORGANIZATION_ID="${org_id}"

export SIGNING_IDENTITY="${identity}"
export RELEASE_VERSION="${version}"
scripts/fetch-helpers.sh
scripts/build-aria2.sh
scripts/release/build-release-app.sh

scripts/release/sign-bundle.sh dist/umbilical.app "${identity}" "${root}"
scripts/check-no-get-task-allow.sh dist/umbilical.app
scripts/ci/yt-dlp-version.sh dist/umbilical.app
python3 scripts/release/release_tools.py check-built-app \
  --app dist/umbilical.app \
  --version "${version}" \
  --signed

minimum="$(
  plutil -extract LSMinimumSystemVersion raw -o - dist/umbilical.app/Contents/Info.plist
)" || exit 1

dmg="dist/umbilical-${version}.dmg"
scripts/release/make-dmg.sh dist/umbilical.app "${dmg}"
# A disk image is not a bundle. Timestamp the signature. Do not request the hardened runtime on the dmg.
codesign --force --sign "${identity}" --timestamp "${dmg}"
codesign --verify --verbose=2 "${dmg}"
dmg_dump="$(codesign -dv --verbose=4 "${dmg}" 2>&1)" || exit 1
if ! printf '%s\n' "${dmg_dump}" | grep -q 'Authority=Developer ID Application:'; then
  echo "dmg is not signed with Developer ID" >&2
  exit 1
fi
if ! printf '%s\n' "${dmg_dump}" | grep -q 'Timestamp='; then
  echo "dmg signature has no timestamp" >&2
  exit 1
fi

scripts/release/notarize-dmg.sh "${dmg}"

tools="${RUNNER_TEMP}/sparkle-tools"
scripts/release/fetch-sparkle-tools.sh "${tools}"
sign_update="${tools}/bin/sign_update"

signature_file="${RUNNER_TEMP}/dmg-signature.txt"
if ! "${sign_update}" --ed-key-file "${sparkle_key}" "${dmg}" \
  >"${signature_file}" 2>"${RUNNER_TEMP}/sign-update.err"; then
  echo "sign_update failed on the dmg" >&2
  exit 1
fi

previous="${RUNNER_TEMP}/previous-appcast.xml"
view_err="${RUNNER_TEMP}/gh-release-view.err"
rm -f "${previous}" "${view_err}"
if asset_names="$(gh release view --repo ks1686/umbilical --json assets --jq '.assets[].name' 2>"${view_err}")"; then
  if printf '%s\n' "${asset_names}" | grep -qx 'appcast.xml'; then
    gh release download --repo ks1686/umbilical \
      --pattern appcast.xml \
      --output "${previous}" \
      --clobber
  else
    echo "latest release has no appcast yet"
  fi
elif grep -Eq 'release not found|no releases found' "${view_err}"; then
  echo "no previous GitHub release"
else
  echo "could not read the latest GitHub release; refusing to drop appcast history" >&2
  cat "${view_err}" >&2
  exit 1
fi

appcast="dist/appcast.xml"
if [[ -f "${previous}" ]]; then
  python3 scripts/release/release_tools.py render-appcast \
    --version "${version}" \
    --short-version "${version}" \
    --minimum "${minimum}" \
    --signature-file "${signature_file}" \
    --dmg "${dmg}" \
    --output "${appcast}" \
    --previous "${previous}"
else
  python3 scripts/release/release_tools.py render-appcast \
    --version "${version}" \
    --short-version "${version}" \
    --minimum "${minimum}" \
    --signature-file "${signature_file}" \
    --dmg "${dmg}" \
    --output "${appcast}"
fi

if ! "${sign_update}" --ed-key-file "${sparkle_key}" "${appcast}" \
  >"${RUNNER_TEMP}/sign-update-xml.out" 2>"${RUNNER_TEMP}/sign-update-xml.err"; then
  echo "sign_update failed on the appcast" >&2
  exit 1
fi
if ! "${sign_update}" --verify --ed-key-file "${sparkle_key}" "${appcast}" \
  >"${RUNNER_TEMP}/sign-update-xml.out" 2>"${RUNNER_TEMP}/sign-update-xml.err"; then
  echo "signed appcast did not verify" >&2
  exit 1
fi

ed_signature="$(
  python3 - "${signature_file}" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip()
match = re.fullmatch(r'sparkle:edSignature="([A-Za-z0-9+/=]+)" length="[0-9]+"', text)
if match is None:
    sys.exit("could not read the dmg ed signature")
sys.stdout.write(match.group(1))
PY
)" || exit 1
if ! "${sign_update}" --verify --ed-key-file "${sparkle_key}" "${dmg}" "${ed_signature}" \
  >"${RUNNER_TEMP}/sign-update-xml.out" 2>"${RUNNER_TEMP}/sign-update-xml.err"; then
  echo "dmg ed signature did not verify" >&2
  exit 1
fi

sha_file="dist/umbilical-${version}.dmg.sha256"
sha256="$(scripts/release/sha256-file.sh "${dmg}" "${sha_file}")" || exit 1
cask="dist/umbilical.rb"
python3 scripts/release/release_tools.py render-cask \
  --version "${version}" \
  --sha256 "${sha256}" \
  --output "${cask}"

notes="${RUNNER_TEMP}/release-notes.md"
cat >"${notes}" <<EOF
umbilical ${version}

SHA-256: ${sha256}

The dmg is notarized. appcast.xml is the Sparkle feed.
umbilical.rb is a Homebrew cask draft. It is not pushed to ks1686/homebrew-tap.
EOF

if gh release view "${tag}" --repo ks1686/umbilical >/dev/null 2>&1; then
  gh release upload "${tag}" --repo ks1686/umbilical --clobber \
    "${dmg}" "${sha_file}" "${cask}" "${appcast}"
else
  gh release create "${tag}" --repo ks1686/umbilical --verify-tag \
    --title "umbilical ${version}" \
    --notes-file "${notes}" \
    "${dmg}" "${sha_file}" "${cask}" "${appcast}"
fi

echo "published ${tag}"
