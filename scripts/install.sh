#!/bin/sh
# fen installer — download a prebuilt static binary and place it on PATH.
#
# Usage:
#   curl -fsSL https://acmiyaguchi.github.io/fen/install.sh | sh
#
# fen ships fully-static musl binaries for Linux only; there is no toolchain to
# bootstrap, so this script just picks the right release asset, verifies its
# checksum, and installs it. On non-Linux hosts, build from source instead
# (nix build .#fen, or make fen — see docs/distribution.md).
#
# Environment overrides:
#   FEN_VERSION   release tag to install (e.g. v0.6.2); default: latest
#   FEN_BIN_DIR   install directory; default: $HOME/.local/bin
#   FEN_ARCH      asset slug override; e.g. linux-armv7-n900-musleabihf-static
#                 for the N900-tuned ARMv7 build (the generic armv7 build is the
#                 safe default and runs on the N900 too)

set -eu

REPO="acmiyaguchi/fen"
RELEASES="https://github.com/${REPO}/releases"

err() {
  echo "fen install: $*" >&2
  exit 1
}

# Pick a downloader once; the helpers below branch on $DL.
if command -v curl >/dev/null 2>&1; then
  DL=curl
elif command -v wget >/dev/null 2>&1; then
  DL=wget
else
  err "need curl or wget to download files"
fi

# fetch URL ($1) to a file path ($2).
fetch_to() {
  case "$DL" in
    curl) curl -fsSL -o "$2" "$1" ;;
    wget) wget -qO "$2" "$1" ;;
  esac
}

# resolve the latest release tag by following the releases/latest redirect.
# Avoids the GitHub API (no jq, no unauthenticated rate limit).
latest_tag() {
  case "$DL" in
    curl) url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "${RELEASES}/latest") ;;
    # wget prints the resolved Location to stderr while spidering.
    wget) url=$(wget -q -S --spider --max-redirect=5 "${RELEASES}/latest" 2>&1 \
      | awk '/^  *Location:/ {print $2}' | tail -n1) ;;
  esac
  case "$url" in
    */tag/*) echo "${url##*/tag/}" ;;
    *) err "could not resolve latest release tag (got: ${url:-empty})" ;;
  esac
}

# map uname to a release asset slug.
detect_asset() {
  os=$(uname -s)
  [ "$os" = "Linux" ] || err "prebuilt binaries are Linux-only (detected: $os).
Build from source instead: nix build .#fen, or make fen.
See https://github.com/${REPO}/blob/main/docs/distribution.md"

  arch=$(uname -m)
  case "$arch" in
    x86_64 | amd64) echo "linux-x86_64-musl-static" ;;
    aarch64 | arm64) echo "linux-aarch64-musl-static" ;;
    armv7l | armv6l) echo "linux-armv7-musleabihf-static" ;;
    *) err "unsupported architecture: $arch
Recognized: x86_64, aarch64, armv7l. Set FEN_ARCH to override, or build from source." ;;
  esac
}

# verify file $1 against SHA256SUMS file $2 (whose entry names the basename of $1).
# Uses prefixed locals because POSIX sh functions share the global scope.
verify_sha256() {
  v_file=$1
  v_sums=$2
  v_name=$(basename "$v_file")
  v_line=$(grep -E "[[:space:]]\*?${v_name}\$" "$v_sums" || true)
  [ -n "$v_line" ] || err "no checksum for $v_name in SHA256SUMS"
  v_expected=$(echo "$v_line" | awk '{print $1}')

  if command -v sha256sum >/dev/null 2>&1; then
    v_actual=$(sha256sum "$v_file" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    v_actual=$(shasum -a 256 "$v_file" | awk '{print $1}')
  else
    echo "fen install: warning: no sha256sum/shasum found, skipping checksum verification" >&2
    return 0
  fi

  [ "$v_actual" = "$v_expected" ] || err "checksum mismatch for $v_name
  expected: $v_expected
  actual:   $v_actual"
}

main() {
  asset=${FEN_ARCH:-$(detect_asset)}
  tag=${FEN_VERSION:-$(latest_tag)}
  bin_dir=${FEN_BIN_DIR:-"$HOME/.local/bin"}

  file="fen-${tag}-${asset}"
  base="${RELEASES}/download/${tag}"

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fen-install.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT INT TERM

  echo "fen install: downloading ${file} (${tag})"
  fetch_to "${base}/${file}" "${tmp}/${file}"
  fetch_to "${base}/SHA256SUMS" "${tmp}/SHA256SUMS"

  verify_sha256 "${tmp}/${file}" "${tmp}/SHA256SUMS"

  mkdir -p "$bin_dir"
  chmod +x "${tmp}/${file}"
  mv -f "${tmp}/${file}" "${bin_dir}/fen"

  echo "fen install: installed to ${bin_dir}/fen"
  "${bin_dir}/fen" --version || true

  case ":${PATH}:" in
    *":${bin_dir}:"*) ;;
    *)
      echo
      echo "fen install: ${bin_dir} is not on your PATH. Add it with:"
      echo "  export PATH=\"${bin_dir}:\$PATH\""
      ;;
  esac
}

main "$@"
