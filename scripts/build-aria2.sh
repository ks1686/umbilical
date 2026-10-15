#!/bin/sh
# Build aria2 without the WebSocket server.
# rpc-allow-origin-all=false does not reject a browser WebSocket handshake
# when that server is compiled in, so the bundled binary disables it.
# usage: build-aria2.sh PREFIX [TARBALL]
set -eu

prefix=${1:-/tmp/aria2-install}
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tarball=${2:-/tmp/aria2-1.37.0.tar.xz}
expected="$root/helpers/checksums/aria2-1.37.0.tar.xz.sha256"

if [ -f "$tarball" ] && "$root/scripts/verify-tarball-hash.sh" "$tarball" "$expected"; then
  :
else
  "$root/scripts/fetch-aria2-source.sh" "$tarball"
fi

source_tree=$(mktemp -d)
trap 'rm -rf "$source_tree"' EXIT
tar -xf "$tarball" -C "$source_tree"
cd "$source_tree/aria2-1.37.0"

if [ "$(uname)" = "Darwin" ]; then
  if command -v brew >/dev/null 2>&1; then
    brew_prefix=$(brew --prefix)
    export PKG_CONFIG_PATH="${brew_prefix}/opt/libxml2/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  fi
  ./configure --prefix="$prefix" --disable-websocket --with-appletls --disable-nls
else
  ./configure --prefix="$prefix" --disable-websocket --with-openssl --disable-nls
fi

if command -v nproc >/dev/null 2>&1; then
  jobs=$(nproc)
elif command -v sysctl >/dev/null 2>&1; then
  jobs=$(sysctl -n hw.ncpu)
else
  jobs=2
fi

make -j"$jobs"
make install
trap - EXIT
