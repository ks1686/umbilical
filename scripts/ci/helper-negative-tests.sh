#!/usr/bin/env bash
# Feed a tampered SHA2-256SUMS, a bad signature, and a wrong tarball hash to
# the helper scripts. Each rejection must exit non-zero. Valid inputs must pass.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lock_file="${root}/helpers/yt-dlp.lock"

lock_get() {
  local key="$1"
  awk -F= -v key="$key" '
    $1 == key {
      print substr($0, index($0, "=") + 1)
      exit
    }
  ' "$lock_file"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

keyring_snapshot() {
  local dir="$1"
  (
    cd "$dir"
    find . -print | LC_ALL=C sort | while IFS= read -r path; do
      if [[ -f "$path" ]]; then
        sha256sum "$path"
      else
        printf 'dir %s\n' "$path"
      fi
    done
  )
}

echo "Release copy fails when yt-dlp is missing"
empty_src="${work}/empty-src"
mkdir -p "$empty_src"
release_log=""
if release_log="$(
  SRCROOT="$empty_src" \
    TARGET_BUILD_DIR="${work}/build" \
    WRAPPER_NAME="umbilical.app" \
    CONFIGURATION="Release" \
    "${root}/scripts/copy-bundled-yt-dlp.sh" 2>&1
)"; then
  echo "Release build continued without yt-dlp" >&2
  printf '%s\n' "$release_log" >&2
  exit 1
fi
case "$release_log" in
  *"missing helpers/bin/yt-dlp"*) ;;
  *)
    echo "Release failure was not a missing yt-dlp" >&2
    printf '%s\n' "$release_log" >&2
    exit 1
    ;;
esac

echo "Debug copy warns and continues when yt-dlp is missing"
debug_log=""
if ! debug_log="$(
  SRCROOT="$empty_src" \
    TARGET_BUILD_DIR="${work}/build" \
    WRAPPER_NAME="umbilical.app" \
    CONFIGURATION="Debug" \
    "${root}/scripts/copy-bundled-yt-dlp.sh" 2>&1
)"; then
  echo "Debug build failed without yt-dlp" >&2
  printf '%s\n' "$debug_log" >&2
  exit 1
fi
case "$debug_log" in
  *"warning: missing helpers/bin/yt-dlp; continuing"*) ;;
  *)
    echo "Debug build did not warn that yt-dlp is missing" >&2
    printf '%s\n' "$debug_log" >&2
    exit 1
    ;;
esac

helper_entitlements="${root}/helpers/yt-dlp.entitlements"
app_entitlements="${root}/App/umbilical.entitlements"
for key in \
  com.apple.security.cs.disable-library-validation \
  com.apple.security.cs.allow-unsigned-executable-memory \
  com.apple.security.cs.allow-jit
do
  if ! grep -q "$key" "$helper_entitlements"; then
    echo "helper entitlements missing ${key}" >&2
    exit 1
  fi
  if grep -q "$key" "$app_entitlements"; then
    echo "app entitlements include ${key}" >&2
    exit 1
  fi
done
if grep -q 'com.apple.security.cs.allow-dyld-environment-variables' \
  "$helper_entitlements" "$app_entitlements"
then
  echo "allow-dyld-environment-variables is set" >&2
  exit 1
fi
echo "yt-dlp entitlements stay on the helper"

if grep -q 'keychain-access-groups' "${app_entitlements}"; then
  echo "Xcode Release entitlements must not include keychain-access-groups" >&2
  exit 1
fi
developer_entitlements="${root}/App/umbilical-developer-id.entitlements"
if ! grep -Fq '7R2VPW8GH4.me.peapod.umbilical' "${developer_entitlements}"; then
  echo "Developer ID entitlements must name 7R2VPW8GH4.me.peapod.umbilical" >&2
  exit 1
fi
if grep -Fq 'AppIdentifierPrefix' "${developer_entitlements}" \
  || grep -Fq '*' "${developer_entitlements}"
then
  echo "Developer ID keychain access group must be the exact team id and bundle id" >&2
  exit 1
fi
if grep -q 'CODE_SIGN_ENTITLEMENTS: App/umbilical-developer-id.entitlements' \
  "${root}/project.yml"
then
  echo "Xcode must not sign with the Developer ID keychain entitlements" >&2
  exit 1
fi
for extra in \
  "${app_entitlements}" \
  "${root}/App/umbilical-debug.entitlements" \
  "${root}/Extension/Extension.entitlements" \
  "${root}/helpers/yt-dlp.entitlements"
do
  if grep -q 'keychain-access-groups' "${extra}"; then
    echo "keychain-access-groups leaked into ${extra}" >&2
    exit 1
  fi
done
echo "keychain-access-groups stays off the Xcode Release entitlements"

echo "Release copy fails when aria2c is missing"
aria_release_log=""
if aria_release_log="$(
  SRCROOT="$empty_src" \
    TARGET_BUILD_DIR="${work}/build" \
    WRAPPER_NAME="umbilical.app" \
    CONFIGURATION="Release" \
    "${root}/scripts/copy-bundled-aria2.sh" 2>&1
)"; then
  echo "Release build continued without aria2c" >&2
  printf '%s\n' "$aria_release_log" >&2
  exit 1
fi
case "$aria_release_log" in
  *"missing helpers/bin/aria2c"*) ;;
  *)
    echo "Release failure was not a missing aria2c" >&2
    printf '%s\n' "$aria_release_log" >&2
    exit 1
    ;;
esac

echo "Debug copy warns and continues when aria2c is missing"
aria_debug_log=""
if ! aria_debug_log="$(
  SRCROOT="$empty_src" \
    TARGET_BUILD_DIR="${work}/build" \
    WRAPPER_NAME="umbilical.app" \
    CONFIGURATION="Debug" \
    "${root}/scripts/copy-bundled-aria2.sh" 2>&1
)"; then
  echo "Debug build failed without aria2c" >&2
  printf '%s\n' "$aria_debug_log" >&2
  exit 1
fi
case "$aria_debug_log" in
  *"warning: missing helpers/bin/aria2c; continuing"*) ;;
  *)
    echo "Debug build did not warn that aria2c is missing" >&2
    printf '%s\n' "$aria_debug_log" >&2
    exit 1
    ;;
esac

sums_url="$(lock_get sums_url)"
sig_url="$(lock_get sums_sig_url)"
case "$sums_url" in
  https://github.com/yt-dlp/yt-dlp/releases/download/*/SHA2-256SUMS) ;;
  *)
    echo "unexpected sums URL" >&2
    exit 1
    ;;
esac
case "$sig_url" in
  https://github.com/yt-dlp/yt-dlp/releases/download/*/SHA2-256SUMS.sig) ;;
  *)
    echo "unexpected signature URL" >&2
    exit 1
    ;;
esac

curl --fail --silent --show-error --location --retry 3 \
  --output "${work}/SHA2-256SUMS" "$sums_url"
curl --fail --silent --show-error --location --retry 3 \
  --output "${work}/SHA2-256SUMS.sig" "$sig_url"

fake_home="${work}/caller-home"
mkdir -p "${fake_home}/.gnupg"
chmod 700 "${fake_home}/.gnupg"
printf 'untouched\n' >"${fake_home}/.gnupg/marker"
before_keyring="$(keyring_snapshot "$fake_home")"

echo "valid signature is accepted without writing the caller keyring"
env HOME="${fake_home}" GNUPGHOME="${fake_home}/.gnupg" \
  "${root}/scripts/fetch-helpers.sh" \
  --verify-sums "${work}/SHA2-256SUMS" "${work}/SHA2-256SUMS.sig"
env -u GNUPGHOME HOME="${fake_home}" \
  "${root}/scripts/fetch-helpers.sh" \
  --verify-sums "${work}/SHA2-256SUMS" "${work}/SHA2-256SUMS.sig"

after_keyring="$(keyring_snapshot "$fake_home")"
if [[ "$before_keyring" != "$after_keyring" ]]; then
  echo "caller keyring changed during signature verification" >&2
  printf 'before:\n%s\n' "$before_keyring" >&2
  printf 'after:\n%s\n' "$after_keyring" >&2
  exit 1
fi

cp "${work}/SHA2-256SUMS" "${work}/SHA2-256SUMS.tampered"
printf 'tampered\n' >>"${work}/SHA2-256SUMS.tampered"
echo "tampered SHA2-256SUMS is rejected"
if "${root}/scripts/fetch-helpers.sh" \
  --verify-sums "${work}/SHA2-256SUMS.tampered" "${work}/SHA2-256SUMS.sig"
then
  echo "tampered SHA2-256SUMS was accepted" >&2
  exit 1
fi

awk '
  /-----BEGIN PGP SIGNATURE-----/ { print; inside = 1; next }
  /-----END PGP SIGNATURE-----/ { inside = 0; print; next }
  inside && !flipped && length($0) > 8 {
    first = substr($0, 1, 1)
    replacement = (first == "A" ? "B" : "A")
    print replacement substr($0, 2)
    flipped = 1
    next
  }
  { print }
' "${work}/SHA2-256SUMS.sig" >"${work}/SHA2-256SUMS.sig.bad"

echo "bad signature is rejected"
if "${root}/scripts/fetch-helpers.sh" \
  --verify-sums "${work}/SHA2-256SUMS" "${work}/SHA2-256SUMS.sig.bad"
then
  echo "bad signature was accepted" >&2
  exit 1
fi

printf 'not the aria2 tarball\n' >"${work}/wrong.tar.xz"
echo "wrong tarball hash is rejected"
if "${root}/scripts/build-aria2.sh" --verify-file "${work}/wrong.tar.xz"; then
  echo "wrong tarball hash was accepted" >&2
  exit 1
fi

echo "valid tarball hash is accepted"
"${root}/scripts/build-aria2.sh" --verify-tarball
echo "helper rejection checks passed"
