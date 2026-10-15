#!/usr/bin/env bash
# Build the pinned aria2c, then run the engine tests against that binary.
# UMB_REQUIRE_ARIA2=1 makes a missing binary a failure instead of a skip.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if [[ "$(uname -s)" == "Darwin" ]]; then
  scripts/build-aria2.sh
  aria2="${root}/helpers/bin/aria2c"
else
  prefix="${root}/helpers/linux"
  scripts/build-aria2-linux.sh "$prefix"
  aria2="${prefix}/bin/aria2c"
fi

if [[ ! -x "$aria2" ]]; then
  echo "aria2c was not produced at ${aria2}" >&2
  exit 1
fi

export ARIA2C="$aria2"
export UMB_REQUIRE_ARIA2=1
swift test
