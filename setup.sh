#!/bin/sh

set -eu

url=${NFBAN_URL:-https://raw.githubusercontent.com/dgavrilov/nfban/master/nfban}
dest=${NFBAN_PATH:-/usr/local/sbin/nfban}

tmp=
cleanup() {
  if [ -n "$tmp" ]; then
    rm -f -- "$tmp"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

if [ "$(id -u)" -ne 0 ]; then
  die 'must run as root (try piping to sudo sh)'
fi

command -v bash >/dev/null 2>&1 || die 'bash is required'

tmp=$(mktemp)
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$url" -o "$tmp" || die "failed to download $url"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$tmp" "$url" || die "failed to download $url"
else
  die 'curl or wget is required'
fi

IFS= read -r first_line <"$tmp" || first_line=
if [ ! -s "$tmp" ] || [ "$first_line" != '#!/usr/bin/env bash' ] || ! bash -n "$tmp" 2>/dev/null; then
  die 'downloaded file is not a valid nfban script'
fi

mkdir -p -- "$(dirname -- "$dest")"
install -o root -g root -m 755 -- "$tmp" "$dest"
rm -f -- "$tmp"
tmp=

"$dest" init
systemctl start nfban
