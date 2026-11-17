#!/bin/bash
# Run a command in a private mount namespace whose /tmp is a symlink to /private/tmp.
# Host directories are bind-mounted read-only. The private tmpfs is the only
# writable system temporary directory. This script never removes a directory
# that still has a mount under it.
set -euo pipefail

if [[ "${1:-}" == "--setup" ]]; then
  shift
  root="$1"
  uid="$2"
  gid="$3"
  home="$4"
  bash_bin="$5"
  shift 5
  [[ "$(id -u)" -eq 0 ]] || exit 1
  mkdir -p "$root/private/tmp" "$root/var/tmp" "$root/proc" "$root/dev" "$root/root"
  mount -t tmpfs -o mode=1777 tmpfs "$root/private/tmp"
  mount -t tmpfs -o mode=1777 tmpfs "$root/var/tmp"
  ln -s private/tmp "$root/tmp"
  ro_bind() {
    local src="$1"
    local dest="$root$1"
    [[ -d "$src" ]] || return 0
    mkdir -p "$dest"
    mount --bind "$src" "$dest"
    mount -o remount,bind,ro "$dest"
  }
  ro_bind /bin
  ro_bind /lib
  ro_bind /lib64
  ro_bind /usr
  ro_bind /etc
  ro_bind /opt
  ro_bind /agent
  ro_bind /home
  if [[ -d /opt/cursor/artifacts ]]; then
    mkdir -p "$root/opt/cursor/artifacts"
    mount --bind /opt/cursor/artifacts "$root/opt/cursor/artifacts"
  fi
  mount --bind /proc "$root/proc"
  ln -s /proc/self/fd "$root/dev/fd"
  ln -s fd/0 "$root/dev/stdin"
  ln -s fd/1 "$root/dev/stdout"
  ln -s fd/2 "$root/dev/stderr"
  for node in null zero urandom random tty; do
    if [[ -e "/dev/$node" ]]; then
      touch "$root/dev/$node"
      mount --bind "/dev/$node" "$root/dev/$node"
    fi
  done
  if [[ -x /tmp/bash-3.2.57/bash ]]; then
    mkdir -p "$root/private/tmp/bash-3.2.57"
    cp -a /tmp/bash-3.2.57/bash "$root/private/tmp/bash-3.2.57/bash"
    chmod 755 "$root/private/tmp/bash-3.2.57/bash"
  fi
  if [[ "$bash_bin" == /tmp/* && ! -x "$root/private/tmp/${bash_bin#/tmp/}" ]]; then
    rel="${bash_bin#/tmp/}"
    mkdir -p "$root/private/tmp/$(dirname "$rel")"
    cp -a "$bash_bin" "$root/private/tmp/$rel"
    chmod 755 "$root/private/tmp/$rel"
  fi
  inner_status=0
  chroot "$root" /usr/bin/env \
    HOME="$home" \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    USER="${UMB_ORIG_USER:-}" \
    LOGNAME="${UMB_ORIG_LOGNAME:-}" \
    UMB_INSIDE_PRIVATE_TMP=1 \
    UMB_VERIFY_SAVE_LOGS="${UMB_VERIFY_SAVE_LOGS:-}" \
    /usr/bin/setpriv \
    --reuid="$uid" \
    --regid="$gid" \
    --init-groups \
    --inh-caps=-all \
    --bounding-set=-all \
    -- "$bash_bin" "$@" || inner_status=$?
  # Longest mount point first. Do not use findmnt -R on a directory that is
  # not itself a mount: that walks the parent filesystem. Do not remove the
  # chroot while any mount under it remains, including a read-only bind.
  next_mount() {
    awk -v prefix="$root/" '
      index($5, prefix) == 1 { print length($5), $5 }
    ' /proc/self/mountinfo | sort -nr | awk 'NR==1 { sub(/^[0-9]+ /, ""); print; exit }'
  }
  while true; do
    target="$(next_mount || true)"
    [[ -n "$target" ]] || break
    if ! umount "$target"; then
      sleep 0.2
      umount "$target" || {
        echo "enter-private-tmp: not removing $root because $target is still mounted" >&2
        exit "$inner_status"
      }
    fi
  done
  if [[ -n "$(next_mount || true)" ]]; then
    echo "enter-private-tmp: not removing $root because a mount remains" >&2
    exit "$inner_status"
  fi
  rm -rf "$root"
  exit "$inner_status"
fi

if [[ "${UMB_INSIDE_PRIVATE_TMP:-}" == "1" ]]; then
  exec "$@"
fi

if [[ "$#" -lt 2 ]]; then
  echo "usage: enter-private-tmp.sh BASH COMMAND [ARG...]" >&2
  exit 2
fi

bash_bin="$(readlink -f "$1")"
shift
root="$(mktemp -d /tmp/umb-private.XXXXXX)"
home="${HOME:-}"
if [[ -z "$home" ]]; then
  home="$(getent passwd "$(id -un)" | awk -F: '{ print $6 }')"
fi
script_path="$(readlink -f "$0")"
exec sudo -n \
  UMB_VERIFY_SAVE_LOGS="${UMB_VERIFY_SAVE_LOGS:-}" \
  UMB_ORIG_USER="${USER:-$(id -un)}" \
  UMB_ORIG_LOGNAME="${LOGNAME:-${USER:-$(id -un)}}" \
  unshare --mount "$script_path" --setup "$root" "$(id -u)" "$(id -g)" "$home" "$bash_bin" "$@"
