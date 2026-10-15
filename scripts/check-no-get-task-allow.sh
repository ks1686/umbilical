#!/bin/bash
# Fail if a Release umbilical.app carries com.apple.security.get-task-allow.
# Checks the app, every appex, every helper, and any embedded framework.
set -euo pipefail

app="${1:-}"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "usage: scripts/check-no-get-task-allow.sh /path/to/umbilical.app" >&2
  exit 1
fi

failed=0

check() {
  local path="$1"
  local dump status
  status=0
  dump="$(codesign -d --entitlements :- "$path" 2>&1)" || status=$?
  if printf '%s\n' "$dump" | grep -q 'com.apple.security.get-task-allow'; then
    echo "Release signature includes com.apple.security.get-task-allow: ${path}" >&2
    printf '%s\n' "$dump" >&2
    failed=1
    return
  fi
  if [[ "$status" -ne 0 ]]; then
    echo "could not read the Release signature of ${path}" >&2
    printf '%s\n' "$dump" >&2
    failed=1
  fi
}

check "$app"

shopt -s nullglob
appex=("$app"/Contents/PlugIns/*.appex)
if [[ ${#appex[@]} -eq 0 ]]; then
  echo "missing Safari extension in ${app}/Contents/PlugIns" >&2
  failed=1
fi
for item in "${appex[@]}"; do
  check "$item"
done

helpers="$app/Contents/Helpers"
if [[ ! -d "$helpers" ]]; then
  echo "missing ${helpers}" >&2
  failed=1
else
  helper_count=0
  while IFS= read -r -d '' file; do
    helper_count=$((helper_count + 1))
    check "$file"
  done < <(find "$helpers" -type f -print0)
  if [[ "$helper_count" -eq 0 ]]; then
    echo "helpers directory is empty: ${helpers}" >&2
    failed=1
  fi
fi

if [[ -d "$app/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' item; do
    check "$item"
  done < <(find "$app/Contents/Frameworks" \( -type d -name '*.framework' -o -type f -name '*.dylib' \) -print0)
fi

exit "$failed"
