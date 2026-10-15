#!/usr/bin/env bash
# Execute the signed yt-dlp helper inside a built umbilical.app.
# The helper is a PyInstaller binary. This must exit 0. A hang is a failure.
set -euo pipefail

app="${1:-}"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "usage: scripts/ci/yt-dlp-version.sh /path/to/umbilical.app" >&2
  exit 2
fi

helper="${app}/Contents/Helpers/yt-dlp"
if [[ ! -x "$helper" ]]; then
  echo "missing signed yt-dlp helper: ${helper}" >&2
  exit 1
fi

sign_dump="$(codesign -d --verbose=2 "$helper" 2>&1)" || {
  echo "codesign could not read ${helper}" >&2
  printf '%s\n' "$sign_dump" >&2
  exit 1
}
if ! printf '%s\n' "$sign_dump" | grep -q 'flags=.*runtime'; then
  echo "yt-dlp is not signed with the hardened runtime" >&2
  printf '%s\n' "$sign_dump" >&2
  exit 1
fi

entitlements="$(codesign -d --entitlements :- "$helper" 2>&1)" || {
  echo "could not read yt-dlp entitlements" >&2
  printf '%s\n' "$entitlements" >&2
  exit 1
}
if printf '%s\n' "$entitlements" | grep -q 'com.apple.security.get-task-allow'; then
  echo "yt-dlp entitlements include get-task-allow" >&2
  printf '%s\n' "$entitlements" >&2
  exit 1
fi
if printf '%s\n' "$entitlements" | grep -q 'com.apple.security.cs.allow-dyld-environment-variables'; then
  echo "yt-dlp entitlements allow DYLD environment variables" >&2
  printf '%s\n' "$entitlements" >&2
  exit 1
fi

required_keys=(
  com.apple.security.cs.disable-library-validation
  com.apple.security.cs.allow-unsigned-executable-memory
  com.apple.security.cs.allow-jit
)
for key in "${required_keys[@]}"; do
  if ! printf '%s\n' "$entitlements" | grep -q "$key"; then
    echo "yt-dlp entitlements missing ${key}" >&2
    printf '%s\n' "$entitlements" >&2
    exit 1
  fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$helper" --version >"${work}/out" 2>"${work}/err" &
pid=$!
elapsed=0
while kill -0 "$pid" 2>/dev/null; do
  if [[ "$elapsed" -ge 60 ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" || true
    echo "yt-dlp --version did not exit within 60s" >&2
    cat "${work}/err" >&2 || true
    exit 1
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

set +e
wait "$pid"
status=$?
set -e
cat "${work}/out"
if [[ "$status" -ne 0 ]]; then
  echo "yt-dlp --version exited ${status}" >&2
  cat "${work}/err" >&2 || true
  exit "$status"
fi
if [[ ! -s "${work}/out" ]]; then
  echo "yt-dlp --version printed nothing" >&2
  cat "${work}/err" >&2 || true
  exit 1
fi
