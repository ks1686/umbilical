#!/usr/bin/env bash
# Build the Release app into dist/umbilical.app.
# Xcode itself always signs ad hoc. Nested Sparkle XPC services break an
# outside-in Developer ID sign during the embed phase.
# SIGNING_IDENTITY is still forwarded to the helper copy scripts.
# scripts/release/sign-bundle.sh applies Developer ID after this build.
# Set RELEASE_VERSION to stamp the tag onto both bundle versions.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${root}"

identity="${SIGNING_IDENTITY:--}"
version="${RELEASE_VERSION:-}"
derived="${RUNNER_TEMP:?}/umbilical-release-derived"

if [[ ! -x helpers/bin/aria2c || ! -f helpers/bin/yt-dlp ]]; then
  echo "helpers are missing; run scripts/fetch-helpers.sh and scripts/build-aria2.sh" >&2
  exit 1
fi

xcodegen generate

args=(
  -project umbilical.xcodeproj
  -scheme umbilical
  -destination "platform=macOS"
  -configuration Release
  -derivedDataPath "${derived}"
  CODE_SIGN_IDENTITY=-
  "ARIA2_CODESIGN_IDENTITY=${identity}"
  "YT_DLP_CODESIGN_IDENTITY=${identity}"
  CODE_SIGN_STYLE=Manual
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGNING_REQUIRED=NO
  ENABLE_HARDENED_RUNTIME=YES
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
)

if [[ -n "${version}" ]]; then
  args+=("MARKETING_VERSION=${version}")
  args+=("CURRENT_PROJECT_VERSION=${version}")
fi

xcodebuild "${args[@]}" build

built="${derived}/Build/Products/Release/umbilical.app"
if [[ ! -d "${built}" ]]; then
  echo "Release app was not built" >&2
  exit 1
fi

mkdir -p dist
rm -rf dist/umbilical.app
ditto "${built}" dist/umbilical.app
