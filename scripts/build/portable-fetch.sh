#!/bin/sh
# portable-fetch.sh — download + checksum-verify (+ extract) one pinned source
# for the non-Nix `make fen` build. Invoked by Makefile file/stamp rules; it is
# the imperative half of the build that Make orchestrates declaratively. Not
# part of the canonical Nix build (nix/artifacts.nix). POSIX sh only.
#
#   portable-fetch.sh tarball URL SHA256 TARBALL DESTDIR [OFFLINE]
#   portable-fetch.sh file    URL SHA256 OUTFILE          [OFFLINE]
set -eu

have() { command -v "$1" >/dev/null 2>&1; }
die()  { printf 'portable-fetch: error: %s\n' "$*" >&2; exit 1; }

download() { # URL OUT
  if have curl;   then curl -fsSL -o "$2" "$1"
  elif have wget; then wget -qO "$2" "$1"
  else die "need curl or wget to download $1"; fi
}

sha_of() { # FILE
  if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
  elif have shasum;  then shasum -a 256 "$1" | cut -d' ' -f1
  else die "need sha256sum or shasum to verify downloads"; fi
}

verify() { # FILE SHA
  _got=$(sha_of "$1")
  [ "$_got" = "$2" ] || die "checksum mismatch for $1: got $_got want $2"
}

fetch() { # URL OUT OFFLINE
  if [ ! -f "$2" ]; then
    [ "${3:-0}" = 1 ] && die "offline: missing $2"
    printf 'portable-fetch: fetching %s\n' "$1"
    mkdir -p "$(dirname "$2")"
    download "$1" "$2"
  fi
}

action=${1:?usage: portable-fetch.sh <tarball|file> ...}
case "$action" in
  tarball)
    url=${2:?}; sha=${3:?}; tarball=${4:?}; dest=${5:?}; offline=${6:-0}
    fetch "$url" "$tarball" "$offline"
    verify "$tarball" "$sha"
    mkdir -p "$dest"
    tar xzf "$tarball" -C "$dest"
    ;;
  file)
    url=${2:?}; sha=${3:?}; out=${4:?}; offline=${5:-0}
    fetch "$url" "$out" "$offline"
    verify "$out" "$sha"
    ;;
  *) die "unknown action: $action (expected tarball|file)" ;;
esac
