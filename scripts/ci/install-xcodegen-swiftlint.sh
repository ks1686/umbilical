#!/usr/bin/env bash
# Install the pinned XcodeGen and SwiftLint used by CI and the Mac release script.
set -euo pipefail

prefix="${HOME}/.local"
work="${RUNNER_TEMP}/tools"
mkdir -p "${prefix}/bin" "${work}"
cd "${work}"

sha256_check() {
  expected="$1"
  file="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "${file}" | awk '{ print $1 }')"
  else
    actual="$(shasum -a 256 "${file}" | awk '{ print $1 }')"
  fi
  if [[ "${actual}" != "${expected}" ]]; then
    echo "checksum mismatch for ${file}" >&2
    echo "expected ${expected}" >&2
    echo "actual   ${actual}" >&2
    exit 1
  fi
}

curl --fail --silent --show-error --location --retry 3 \
  --output xcodegen.zip \
  "https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip"
sha256_check \
  "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806" \
  xcodegen.zip
rm -rf xcodegen
unzip -q xcodegen.zip
PREFIX="${prefix}" bash ./xcodegen/install.sh

curl --fail --silent --show-error --location --retry 3 \
  --output portable_swiftlint.zip \
  "https://github.com/realm/SwiftLint/releases/download/0.65.1/portable_swiftlint.zip"
sha256_check \
  "c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0" \
  portable_swiftlint.zip
rm -rf swiftlint-extract
unzip -q portable_swiftlint.zip -d swiftlint-extract
install -m 0755 swiftlint-extract/swiftlint "${prefix}/bin/swiftlint"

export PATH="${prefix}/bin:${PATH}"
echo "${prefix}/bin" >>"${GITHUB_PATH}"
xcodegen version
swiftlint version
