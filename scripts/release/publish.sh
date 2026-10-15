#!/usr/bin/env bash
# Sign, notarize, and publish a vX.Y.Z tag. Secrets stay in the environment.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${root}"

if [[ -z "${RUNNER_TEMP:-}" ]]; then
  echo "RUNNER_TEMP is empty" >&2
  exit 1
fi
if [[ -z "${GITHUB_REF_NAME:-}" ]]; then
  echo "GITHUB_REF_NAME is empty" >&2
  exit 1
fi

keychain="${RUNNER_TEMP}/umbilical-release.keychain-db"
sparkle_key="${RUNNER_TEMP}/sparkle-ed.key"
identity_file="${RUNNER_TEMP}/signing-identity.txt"

cleanup() {
  rm -f "${sparkle_key}" "${RUNNER_TEMP}/developer-id.p12" "${RUNNER_TEMP}/AuthKey.p8"
  rm -f "${RUNNER_TEMP}/sign-update.err" "${RUNNER_TEMP}/sign-update-xml.err"
  rm -f "${RUNNER_TEMP}/sign-update-xml.out" "${RUNNER_TEMP}/dmg-signature.txt"
  rm -f "${RUNNER_TEMP}/gh-release-view.err"
  if [[ -e "${keychain}" ]]; then
    security delete-keychain "${keychain}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

require_text() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    echo "${name} is empty" >&2
    exit 1
  fi
}

require_text MACOS_SIGN_P12 "${MACOS_SIGN_P12:-}"
require_text MACOS_SIGN_PASSWORD "${MACOS_SIGN_PASSWORD:-}"
require_text MACOS_NOTARY_KEY "${MACOS_NOTARY_KEY:-}"
require_text MACOS_NOTARY_KEY_ID "${MACOS_NOTARY_KEY_ID:-}"
require_text MACOS_NOTARY_ISSUER_ID "${MACOS_NOTARY_ISSUER_ID:-}"
require_text SPARKLE_ED_PRIVATE_KEY "${SPARKLE_ED_PRIVATE_KEY:-}"
require_text POLAR_ORGANIZATION_ID "${POLAR_ORGANIZATION_ID:-}"
if [[ -z "${GH_TOKEN:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
  export GH_TOKEN="${GITHUB_TOKEN}"
fi
if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "GH_TOKEN is empty" >&2
  exit 1
fi

version="$(python3 scripts/release/release_tools.py version-from-tag --tag "${GITHUB_REF_NAME}")"
python3 scripts/release/release_tools.py assert-repo
python3 scripts/release/release_tools.py check-sparkle-key --info-plist App/Info.plist
python3 scripts/release/release_tools.py write-licensing-xcconfig \
  --dest Config/Licensing.local.xcconfig

scripts/release/import-developer-id.sh "${keychain}"
identity="$(cat "${identity_file}")"
require_text "signing identity" "${identity}"

export SIGNING_IDENTITY="${identity}"
export RELEASE_VERSION="${version}"
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
)"

dmg="dist/umbilical-${version}.dmg"
scripts/release/make-dmg.sh dist/umbilical.app "${dmg}"
codesign --force --sign "${identity}" --timestamp "${dmg}"
codesign --verify --verbose=2 "${dmg}"
dmg_dump="$(codesign -dv --verbose=4 "${dmg}" 2>&1)"
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

umask 077
SPARKLE_KEY_OUT="${sparkle_key}" python3 - <<'PY'
import os
import pathlib
import sys

value = os.environ.get("SPARKLE_ED_PRIVATE_KEY", "").strip()
if not value:
    sys.exit("SPARKLE_ED_PRIVATE_KEY is empty")
path = pathlib.Path(os.environ["SPARKLE_KEY_OUT"])
path.write_text(value + "\n", encoding="utf-8")
os.chmod(path, 0o600)
PY

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
)"
if ! "${sign_update}" --verify --ed-key-file "${sparkle_key}" "${dmg}" "${ed_signature}" \
  >"${RUNNER_TEMP}/sign-update-xml.out" 2>"${RUNNER_TEMP}/sign-update-xml.err"; then
  echo "dmg ed signature did not verify" >&2
  exit 1
fi

sha_file="dist/umbilical-${version}.dmg.sha256"
sha256="$(scripts/release/sha256-file.sh "${dmg}" "${sha_file}")"
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

tag="v${version}"
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
