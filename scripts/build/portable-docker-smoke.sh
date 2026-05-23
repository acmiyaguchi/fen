#!/bin/sh
# portable-docker-smoke.sh — exercise the non-Nix `make fen` build in a clean
# Debian container, the way an apt-based user would: install the documented
# toolchain, fetch the third-party sources over the network, build, and smoke
# the binary. This is the realistic CI/maintainer check for the portable path.
#
# It cannot run inside `nix flake check` (that build sandbox has no Docker and
# no network), so it is a standalone target. Requires Docker (set DOCKER=podman
# to use podman) and network access. The checkout is mounted read-only and
# copied inside the container, so the host tree is untouched. POSIX sh.
set -eu

DOCKER=${DOCKER:-docker}
IMAGE=${IMAGE:-debian:stable-slim}
command -v "$DOCKER" >/dev/null 2>&1 || { echo "portable-docker-smoke: $DOCKER not found (set DOCKER=)" >&2; exit 1; }

echo "portable-docker-smoke: building 'make fen' in $IMAGE"
exec "$DOCKER" run --rm -v "$(pwd):/src:ro" "$IMAGE" sh -eu -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    build-essential libcurl4-openssl-dev liblua5.4-dev lua5.4 \
    pkg-config zip ca-certificates wget git >/dev/null

  # Build-time Fennel CLI. The *embedded* fennel.lua is fetched and sha256-
  # verified by the Makefile from the pinned tarball; this CLI only drives
  # compilation, and its output is validated by the smoke run below.
  wget -qO /usr/local/lib/fennel.lua https://fennel-lang.org/downloads/fennel-1.6.1
  printf "#!/bin/sh\nexec lua5.4 /usr/local/lib/fennel.lua \"\$@\"\n" > /usr/local/bin/fennel
  chmod +x /usr/local/bin/fennel

  cp -a /src /work && cd /work
  git config --global --add safe.directory /work 2>/dev/null || true
  rm -rf build third_party/.cache    # ignore any host-built cache from the :ro copy

  make fen
  ./build/fen --version
  ./build/fen --help >/dev/null
  echo "portable-docker-smoke: ok"
'
