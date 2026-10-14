#!/usr/bin/env bash
# Build a universal aria2c from the pinned official source tarball.
#
# The recipe configures a static build (--enable-static --disable-shared and
# ARIA2_STATIC=yes) with --with-appletls and without OpenSSL or GnuTLS.
# It compiles arm64 and x86_64 separately, then combines them with lipo.
# macOS cannot fully static-link libSystem, so the binary still links the
# system libc++, libz, libxml2, and Apple frameworks. It must not link
# OpenSSL, GnuTLS, or a Homebrew library.
#
# Usage:
#   scripts/build-aria2.sh
#   scripts/build-aria2.sh --verify-tarball
#
# --verify-tarball checks the recorded SHA-256 and does not compile.
# That mode runs on any OS. The compile requires macOS 14 or later.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="${root}/helpers/aria2.lock"
mode="build"

if [[ "${1:-}" == "--verify-tarball" ]]; then
  mode="verify"
elif [[ $# -ne 0 ]]; then
  echo "usage: scripts/build-aria2.sh [--verify-tarball]" >&2
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

require_url "$tarball_url" "https://github.com/aria2/aria2/releases/download/release-${version}/"
if [[ "$tarball_sha256" != "$(printf '%s' "$tarball_sha256" | tr -cd '0-9a-f')" ]] \
  || [[ "${#tarball_sha256}" -ne 64 ]]; then
  echo "tarball_sha256 in ${lock_file} is not 64 hex characters" >&2
  exit 1
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

for tool in curl xcrun clang clang++ make lipo otool file pkg-config; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: ${tool}" >&2
    exit 1
  fi
done

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

  (
    set -euo pipefail
    cd "${dest}/tree"
    export CC="clang"
    export CXX="clang++"
    export CFLAGS="$flags"
    export CXXFLAGS="$flags"
    export LDFLAGS="$flags"
    export PKG_CONFIG_PATH="$pcdir"
    unset PKG_CONFIG_SYSROOT_DIR || true
    if ! ./configure \
      --build="${build_triple}" \
      --host="${host_triple}" \
      --prefix=/usr/local \
      --enable-static \
      --disable-shared \
      --disable-nls \
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

  local jobs
  jobs="$(sysctl -n hw.ncpu)"
  make -C "${dest}/tree" -j"$jobs"

  local candidate="${dest}/tree/src/aria2c"
  if [[ -f "${dest}/tree/src/.libs/aria2c" ]]; then
    candidate="${dest}/tree/src/.libs/aria2c"
  fi
  if ! file "$candidate" | grep -q 'Mach-O'; then
    echo "aria2c for ${arch} is not a Mach-O binary: ${candidate}" >&2
    file "$candidate" >&2
    exit 1
  fi
  cp "$candidate" "${dest}/aria2c"
  echo "built ${arch}: ${dest}/aria2c"
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

binary_sha256="$(sha256_file "$out" | tr '[:upper:]' '[:lower:]')"
echo "aria2c sha256: ${binary_sha256}"
expected_binary="$(lock_get binary_sha256 | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
if [[ -z "$expected_binary" ]]; then
  echo "binary_sha256 is empty in ${lock_file}" >&2
  echo "Record the sha256 printed above, then rebuild." >&2
  exit 1
fi
if [[ "$expected_binary" != "$binary_sha256" ]]; then
  echo "binary SHA-256 mismatch" >&2
  echo "expected ${expected_binary}" >&2
  echo "actual   ${binary_sha256}" >&2
  exit 1
fi

echo "universal aria2c matches helpers/aria2.lock"
