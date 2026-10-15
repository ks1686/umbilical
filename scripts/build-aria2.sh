#!/usr/bin/env bash
# Build a universal aria2c from the pinned official source tarball.
#
# The recipe configures a static build (--enable-static --disable-shared and
# ARIA2_STATIC=yes) with --with-appletls, --disable-websocket, and without
# OpenSSL or GnuTLS. WebSocket support answers a browser handshake with
# 101 even when rpc-allow-origin-all is false, so the bundled binary
# leaves it out. JSON-RPC stays on HTTP.
# It compiles arm64 and x86_64 separately, then combines them with lipo.
# macOS cannot fully static-link libSystem, so the binary still links the
# system libc++, libz, libxml2, and Apple frameworks. It must not link
# OpenSSL, GnuTLS, or a Homebrew library.
#
# aria2 prints __DATE__ and __TIME__ from FeatureConfig.cc. Those macros
# would change the binary hash on every build. The recipe rewrites them to
# the release instant in helpers/aria2.lock, exports SOURCE_DATE_EPOCH and
# ZERO_AR_DATE, and links with -Wl,-reproducible. After compile, object
# mtimes are pinned to object_mtime (a fixed instant after the macOS SDK
# headers, so make will not rebuild) and the binary is linked twice. The
# slice hashes must match.
#
# Xcode 27's libc++ no longer includes <iterator> through other headers.
# CXXFLAGS pass -include iterator so std::back_inserter still compiles.
# helpers/aria2.lock stores one universal-binary SHA-256 per Xcode and
# clang. The source tarball SHA-256 stays the trust anchor.
#
# Usage:
#   scripts/build-aria2.sh
#   scripts/build-aria2.sh --verify-tarball
#   scripts/build-aria2.sh --verify-file FILE
#
# --verify-tarball checks the recorded SHA-256 and does not compile.
# --verify-file checks FILE against that SHA-256 and does not download.
# Both modes run on any OS. The compile requires macOS 14 or later.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="${root}/helpers/aria2.lock"
mode="build"
verify_file=""

if [[ "${1:-}" == "--verify-tarball" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "usage: scripts/build-aria2.sh [--verify-tarball | --verify-file FILE]" >&2
    exit 2
  fi
  mode="verify"
elif [[ "${1:-}" == "--verify-file" ]]; then
  if [[ $# -ne 2 || -z "${2:-}" ]]; then
    echo "usage: scripts/build-aria2.sh [--verify-tarball | --verify-file FILE]" >&2
    exit 2
  fi
  mode="verify-file"
  verify_file="$2"
elif [[ $# -ne 0 ]]; then
  echo "usage: scripts/build-aria2.sh [--verify-tarball | --verify-file FILE]" >&2
  exit 2
fi

lock_get() {
  local key="$1"
  awk -F= -v key="$key" '
    $1 == key {
      print substr($0, index($0, "=") + 1)
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$lock_file"
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{ print $1 }'
  else
    shasum -a 256 "$file" | awk '{ print $1 }'
  fi
}

require_url() {
  local url="$1"
  local prefix="$2"
  case "$url" in
    "${prefix}"*) ;;
    *)
      echo "refusing unexpected URL: ${url}" >&2
      exit 1
      ;;
  esac
}

download() {
  local url="$1"
  local dest="$2"
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --output "$dest" "$url"
}

version="$(lock_get version)"
tarball_name="$(lock_get tarball_name)"
tarball_url="$(lock_get tarball_url)"
tarball_bytes="$(lock_get tarball_bytes)"
tarball_sha256="$(lock_get tarball_sha256 | tr '[:upper:]' '[:lower:]')"
source_date_epoch="$(lock_get source_date_epoch)"
build_date="$(lock_get build_date)"
build_time="$(lock_get build_time)"
object_mtime="$(lock_get object_mtime)"

require_url "$tarball_url" "https://github.com/aria2/aria2/releases/download/release-${version}/"
if [[ "$tarball_sha256" != "$(printf '%s' "$tarball_sha256" | tr -cd '0-9a-f')" ]] \
  || [[ "${#tarball_sha256}" -ne 64 ]]; then
  echo "tarball_sha256 in ${lock_file} is not 64 hex characters" >&2
  exit 1
fi
case "$source_date_epoch" in
  ''|*[!0-9]*)
    echo "source_date_epoch in ${lock_file} is not an integer" >&2
    exit 1
    ;;
esac
case "$build_date" in
  [A-Z][a-z][a-z]' '[0-9][0-9]' '[0-9][0-9][0-9][0-9]) ;;
  *)
    echo "build_date in ${lock_file} must look like 'Nov 15 2023'" >&2
    exit 1
    ;;
esac
case "$build_time" in
  [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
  *)
    echo "build_time in ${lock_file} must look like '12:07:32'" >&2
    exit 1
    ;;
esac
case "$object_mtime" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9][0-9]) ;;
  *)
    echo "object_mtime in ${lock_file} must look like '210001010000.00'" >&2
    exit 1
    ;;
esac

if [[ "$mode" == "verify-file" ]]; then
  if [[ ! -f "$verify_file" ]]; then
    echo "missing tarball: ${verify_file}" >&2
    exit 1
  fi
  actual="$(sha256_file "$verify_file" | tr '[:upper:]' '[:lower:]')"
  if [[ "$actual" != "$tarball_sha256" ]]; then
    echo "tarball SHA-256 mismatch" >&2
    echo "expected ${tarball_sha256}" >&2
    echo "actual   ${actual}" >&2
    exit 1
  fi
  echo "tarball SHA-256 ok"
  exit 0
fi

src_dir="${root}/helpers/src"
tarball="${src_dir}/${tarball_name}"
mkdir -p "$src_dir"

if [[ -f "$tarball" ]]; then
  actual="$(sha256_file "$tarball" | tr '[:upper:]' '[:lower:]')"
  if [[ "$actual" != "$tarball_sha256" ]]; then
    echo "cached tarball hash does not match the lock file; downloading again" >&2
    rm -f "$tarball"
  fi
fi

if [[ ! -f "$tarball" ]]; then
  download "$tarball_url" "${tarball}.partial"
  mv "${tarball}.partial" "$tarball"
fi

actual="$(sha256_file "$tarball" | tr '[:upper:]' '[:lower:]')"
if [[ "$actual" != "$tarball_sha256" ]]; then
  echo "tarball SHA-256 mismatch" >&2
  echo "expected ${tarball_sha256}" >&2
  echo "actual   ${actual}" >&2
  exit 1
fi

actual_bytes="$(wc -c <"$tarball" | tr -d '[:space:]')"
if [[ "$actual_bytes" != "$tarball_bytes" ]]; then
  echo "tarball size mismatch: expected ${tarball_bytes}, got ${actual_bytes}" >&2
  exit 1
fi

echo "aria2 ${version} tarball SHA-256 ok"

if [[ "$mode" == "verify" ]]; then
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "compiling aria2c requires macOS" >&2
  exit 1
fi

for tool in curl xcrun xcodebuild clang clang++ make lipo otool file pkg-config perl find touch date; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: ${tool}" >&2
    exit 1
  fi
done

validate_toolchain_lines() {
  awk '
    index($0, "toolchain_sha256=") == 1 {
      rest = substr($0, length("toolchain_sha256=") + 1)
      n = split(rest, parts, "|")
      if (n != 3 || parts[1] == "" || parts[2] == "" || parts[3] !~ /^[0-9a-fA-F]{64}$/) {
        print "malformed toolchain_sha256 line: " $0 > "/dev/stderr"
        exit 1
      }
    }
  ' "$lock_file"
}

detect_toolchain() {
  local xcode_line clang_line xcode_output clang_output
  # Read every line. Stopping after the first one closes the pipe, and
  # xcodebuild then aborts with a broken-pipe exception.
  xcode_output="$(xcodebuild -version)"
  xcode_line="${xcode_output%%$'\n'*}"
  xcode_version="$(printf '%s\n' "$xcode_line" | awk '/^Xcode / { print $2; exit }')"
  if [[ -z "$xcode_version" ]]; then
    echo "could not read the Xcode version from: ${xcode_line}" >&2
    exit 1
  fi
  case "$xcode_version" in
    *'|'*)
      echo "Xcode version contains '|': ${xcode_version}" >&2
      exit 1
      ;;
  esac
  xcode_clang="$(xcrun --find clang)"
  xcode_clangxx="$(xcrun --find clang++)"
  clang_output="$("$xcode_clang" --version)"
  clang_line="${clang_output%%$'\n'*}"
  clang_id="$(printf '%s\n' "$clang_line" | sed -n 's/^Apple clang version \([0-9][0-9.]*\) (\([^)]*\)).*/\1 (\2)/p')"
  if [[ -z "$clang_id" ]]; then
    echo "could not read the Apple clang version from: ${clang_line}" >&2
    exit 1
  fi
  case "$clang_id" in
    *'|'*)
      echo "clang version contains '|': ${clang_id}" >&2
      exit 1
      ;;
  esac
  echo "toolchain: ${xcode_version}/${clang_id}"
}

lookup_toolchain_sha256() {
  local xcode="$1"
  local clang="$2"
  awk -v xcode="$xcode" -v clang="$clang" '
    index($0, "toolchain_sha256=") == 1 {
      rest = substr($0, length("toolchain_sha256=") + 1)
      n = split(rest, parts, "|")
      if (n == 3 && parts[1] == xcode && parts[2] == clang) {
        print tolower(parts[3])
        count++
      }
    }
    END {
      if (count == 0) {
        exit 1
      }
      if (count != 1) {
        print "duplicate toolchain_sha256 entries for this Xcode and clang" > "/dev/stderr"
        exit 2
      }
    }
  ' "$lock_file"
}

validate_toolchain_lines
detect_toolchain

stamp_text="$(LC_ALL=C TZ=UTC date -r "$source_date_epoch" "+%b %d %Y %H:%M:%S")"
if [[ "$stamp_text" != "${build_date} ${build_time}" ]]; then
  echo "source_date_epoch does not format as the lock file build stamp" >&2
  echo "expected ${build_date} ${build_time}" >&2
  echo "actual   ${stamp_text}" >&2
  exit 1
fi

export SOURCE_DATE_EPOCH="$source_date_epoch"
export ZERO_AR_DATE=1
export TZ=UTC

sdk="$(xcrun --sdk macosx --show-sdk-path)"
xml_header="${sdk}/usr/include/libxml2/libxml/xmlversion.h"
if [[ ! -f "$xml_header" ]]; then
  echo "macOS SDK is missing libxml2 headers at ${xml_header}" >&2
  exit 1
fi
if [[ ! -e "${sdk}/usr/lib/libxml2.tbd" && ! -e "${sdk}/usr/lib/libxml2.dylib" ]]; then
  echo "macOS SDK is missing libxml2" >&2
  exit 1
fi
if [[ ! -f "${sdk}/usr/include/zlib.h" ]]; then
  echo "macOS SDK is missing zlib.h" >&2
  exit 1
fi

libxml_version="$(sed -n 's/^#define LIBXML_DOTTED_VERSION "\([0-9.][0-9.]*\)".*/\1/p' "$xml_header")"
if [[ -z "$libxml_version" ]]; then
  echo "could not read LIBXML_DOTTED_VERSION from ${xml_header}" >&2
  exit 1
fi

case "$(uname -m)" in
  arm64) build_triple="aarch64-apple-darwin" ;;
  x86_64) build_triple="x86_64-apple-darwin" ;;
  *)
    echo "unsupported machine: $(uname -m)" >&2
    exit 1
    ;;
esac

work="${root}/helpers/build"
rm -rf "$work"
mkdir -p "$work"

build_arch() {
  local arch="$1"
  local host_triple="$2"
  local dest="${work}/${arch}"
  local pcdir="${dest}/pkgconfig"
  local log="${dest}/configure.log"
  local flags="-arch ${arch} -isysroot ${sdk} -mmacosx-version-min=14.0"
  local cxx_flags="${flags} -include iterator"
  local link_flags="${flags} -Wl,-reproducible"

  mkdir -p "$pcdir" "${dest}/tree"
  cat >"${pcdir}/libxml-2.0.pc" <<EOF
prefix=${sdk}/usr
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libxml-2.0
Description: libxml2 from the macOS SDK
Version: ${libxml_version}
Libs: -lxml2
Cflags: -I\${includedir}/libxml2
EOF

  tar -xJf "$tarball" -C "${dest}/tree" --strip-components=1
  freeze_build_stamp "${dest}/tree/src/FeatureConfig.cc"

  (
    set -euo pipefail
    cd "${dest}/tree"
    export CC="$xcode_clang"
    export CXX="$xcode_clangxx"
    export CFLAGS="$flags"
    export CXXFLAGS="$cxx_flags"
    export LDFLAGS="$link_flags"
    export PKG_CONFIG_PATH="$pcdir"
    unset PKG_CONFIG_SYSROOT_DIR || true
    if ! ./configure \
      --build="${build_triple}" \
      --host="${host_triple}" \
      --prefix=/usr/local \
      --enable-static \
      --disable-shared \
      --disable-nls \
      --disable-websocket \
      --with-appletls \
      --without-openssl \
      --without-gnutls \
      --without-libgcrypt \
      --without-libnettle \
      --without-libgmp \
      --without-libssh2 \
      --without-libuv \
      --without-sqlite3 \
      --without-libcares \
      --without-libexpat \
      --with-libxml2 \
      --with-libz \
      ARIA2_STATIC=yes \
      >"$log" 2>&1; then
      cat "$log" >&2
      exit 1
    fi
  )

  if ! grep -Eq '^AppleTLS:[[:space:]]+yes([[:space:]]|$)' "$log"; then
    echo "AppleTLS was not enabled for ${arch}. See ${log}" >&2
    exit 1
  fi
  if ! grep -Eq '^GnuTLS:[[:space:]]+no([[:space:]]|$)' "$log"; then
    echo "GnuTLS was not disabled for ${arch}. See ${log}" >&2
    exit 1
  fi
  if ! grep -Eq '^OpenSSL:[[:space:]]+no([[:space:]]|$)' "$log"; then
    echo "OpenSSL was not disabled for ${arch}. See ${log}" >&2
    exit 1
  fi
  if ! grep -Eq '^Static build:[[:space:]]+yes([[:space:]]|$)' "$log"; then
    echo "static build was not enabled for ${arch}. See ${log}" >&2
    exit 1
  fi
  if ! grep -Eq '^WebSocket:[[:space:]]+no([[:space:]]|$)' "$log"; then
    echo "WebSocket was not disabled for ${arch}. See ${log}" >&2
    exit 1
  fi

  local jobs
  jobs="$(sysctl -n hw.ncpu)"
  make -C "${dest}/tree" -j"$jobs"

  # The first link saw clock-dependent object mtimes. Pin those mtimes and
  # link again. Pinning only the products keeps them newer than SDK headers.
  local first_hash=""
  local attempt
  for attempt in 1 2; do
    link_aria2c "${dest}" "$jobs" "$attempt"
    local linked="${dest}/aria2c"
    local attempt_hash
    attempt_hash="$(sha256_file "$linked" | tr '[:upper:]' '[:lower:]')"
    if [[ "$attempt" == "1" ]]; then
      first_hash="$attempt_hash"
    elif [[ "$attempt_hash" != "$first_hash" ]]; then
      echo "aria2c for ${arch} is not reproducible" >&2
      echo "first  ${first_hash}" >&2
      echo "second ${attempt_hash}" >&2
      exit 1
    fi
  done
  echo "built ${arch}: ${dest}/aria2c"
}

freeze_build_stamp() {
  local file="$1"
  local needle='<< __DATE__ << " " << __TIME__;'
  if ! grep -F "$needle" "$file" >/dev/null; then
    echo "could not find the build stamp in ${file}" >&2
    exit 1
  fi
  BUILD_DATE="$build_date" BUILD_TIME="$build_time" \
    perl -i -pe 's/<< __DATE__ << " " << __TIME__;/<< "$ENV{BUILD_DATE}" << " " << "$ENV{BUILD_TIME}";/' \
    "$file"
  if grep -F '__DATE__' "$file" >/dev/null || grep -F '__TIME__' "$file" >/dev/null; then
    echo "build stamp macros remain in ${file}" >&2
    exit 1
  fi
}

link_aria2c() {
  local dest="$1"
  local jobs="$2"
  local attempt="$3"
  local tree="${dest}/tree"
  local log="${dest}/relink-${attempt}.log"
  find "$tree" -type f \( -name '*.o' -o -name '*.a' -o -name '*.lo' -o -name '*.la' \) \
    -exec touch -t "$object_mtime" {} +
  rm -f "${tree}/src/aria2c" "${tree}/src/.libs/aria2c"
  make -C "${tree}/src" -j"$jobs" aria2c >"$log" 2>&1 || {
    cat "$log" >&2
    exit 1
  }
  if grep -E '(^|[[:space:]])(CC|CXX)[[:space:]]' "$log" >/dev/null; then
    echo "relink ${attempt} recompiled sources for ${dest}" >&2
    cat "$log" >&2
    exit 1
  fi
  if ! grep -E 'CXXLD|CCLD' "$log" >/dev/null; then
    echo "relink ${attempt} did not link aria2c for ${dest}" >&2
    cat "$log" >&2
    exit 1
  fi
  local candidate="${tree}/src/aria2c"
  if [[ -f "${tree}/src/.libs/aria2c" ]]; then
    candidate="${tree}/src/.libs/aria2c"
  fi
  if ! file "$candidate" | grep -q 'Mach-O'; then
    echo "aria2c relink ${attempt} is not a Mach-O binary: ${candidate}" >&2
    file "$candidate" >&2
    exit 1
  fi
  cp "$candidate" "${dest}/aria2c"
}

build_arch arm64 aarch64-apple-darwin
build_arch x86_64 x86_64-apple-darwin

out_dir="${root}/helpers/bin"
out="${out_dir}/aria2c"
mkdir -p "$out_dir"
lipo -create "${work}/arm64/aria2c" "${work}/x86_64/aria2c" -output "$out"
chmod 0755 "$out"

lipo_info="$(lipo -info "$out")"
echo "$lipo_info"
case "$lipo_info" in
  *arm64*) ;;
  *)
    echo "universal binary is missing arm64" >&2
    exit 1
    ;;
esac
case "$lipo_info" in
  *x86_64*) ;;
  *)
    echo "universal binary is missing x86_64" >&2
    exit 1
    ;;
esac

for arch in arm64 x86_64; do
  libs="$(otool -arch "$arch" -L "$out")"
  printf '%s\n' "$libs"
  if printf '%s\n' "$libs" | grep -Ei 'openssl|gnutls|libssl|libcrypto|libgnutls' >/dev/null; then
    echo "${arch} slice links OpenSSL or GnuTLS" >&2
    exit 1
  fi
  if printf '%s\n' "$libs" | grep -E '/opt/homebrew|/usr/local/' >/dev/null; then
    echo "${arch} slice links a non-system library" >&2
    exit 1
  fi
done

version_text="$("$out" -v)"
printf '%s\n' "$version_text"
if ! printf '%s\n' "$version_text" | grep -F "aria2 version ${version}" >/dev/null; then
  echo "built aria2c did not report version ${version}" >&2
  exit 1
fi
if ! printf '%s\n' "$version_text" | grep -F "on        ${build_date} ${build_time}" >/dev/null; then
  echo "built aria2c does not report the frozen build stamp" >&2
  exit 1
fi

binary_sha256="$(sha256_file "$out" | tr '[:upper:]' '[:lower:]')"
echo "aria2c sha256: ${binary_sha256}"
echo "toolchain: ${xcode_version}/${clang_id}"

lookup_status=0
expected_binary="$(lookup_toolchain_sha256 "$xcode_version" "$clang_id" | tr -d '[:space:]')" || lookup_status=$?
case "$lookup_status" in
  0) ;;
  1)
    echo "toolchain changed: ${xcode_version}/${clang_id} has no recorded hash" >&2
    exit 1
    ;;
  *)
    exit "$lookup_status"
    ;;
esac
if [[ "$expected_binary" != "$binary_sha256" ]]; then
  echo "binary SHA-256 mismatch for ${xcode_version}/${clang_id}" >&2
  echo "expected ${expected_binary}" >&2
  echo "actual   ${binary_sha256}" >&2
  exit 1
fi

echo "universal aria2c matches helpers/aria2.lock"
