# Distribution and workflow status

fen is consolidating around one canonical path: Nix builds the runtime and
release artifacts, while the single-file binary plus source overlays drives
normal development.

## Canonical development

Use the single-file runtime from `.#fen` and the checkout wrapper:

```sh
nix build .#fen
FEN_BIN=$PWD/result/bin/fen scripts/dev/fen-dev
```

`scripts/dev/fen-dev` prepends package source roots to `FEN_DEV_PATH` and the flat
first-party extension root to `FEN_EXTENSION_ROOT`. The embedded Fennel compiler
loads `.fnl` directly, so edits are visible after `/reload` without generated
package output.

Fast local checks remain useful:

```sh
fennel scripts/test/fennel-check.fnl
make test
```

The reproducible CI surface is:

```sh
nix flake check
```

## Building without Nix

Nix stays the canonical, reproducible build and the source of every release
artifact.
For people who do not have Nix, `make fen` produces the same single-file binary
by linking against the host's Lua and libcurl instead.
There is no separate `./configure` step: the Makefile probes the toolchain and
fetches the third-party sources itself, only when a portable goal is the make
goal (so `make test` and friends never shell out to pkg-config or the network).
This path is a convenience, not a release path: binaries it produces are not
the published artifacts and carry a `make` source stamp rather than `nix`.

```sh
make fen                    # probe toolchain, fetch sources, compile + embed -> build/fen
sudo make install           # optional: install to $PREFIX/bin (default /usr/local)
make check-portable         # build build/fen and smoke --version/--help/modules (local toolchain)
make check-portable-docker  # build+smoke the whole apt path in a clean Debian container
```

`make check-portable-docker` (needs Docker, set `DOCKER=podman` to switch) runs
the documented `apt install … && make fen` flow on `debian:stable-slim` against
a read-only copy of the checkout, fetching sources over the network like a real
user.
It cannot run under `nix flake check` — that build sandbox has no Docker and no
network — so it is a standalone CI/maintainer check.

The host must provide a C compiler, `pkg-config` (used to locate the system Lua
and libcurl), the `fennel` and `zip` CLIs, a Lua 5.4 interpreter (used only to
build `fennel.lua`), and system libcurl with headers.
On Debian/Raspberry Pi OS that is roughly
`apt install build-essential pkg-config libcurl4-openssl-dev liblua5.4-dev lua5.4 zip`
plus `fennel` (via `luarocks install fennel`).

`make fen` resolves the sources the Nix build normally fetches — kubazip,
lua-cjson, luafilesystem, LuaSocket, fennel, dkjson, and (when no system Lua 5.4 is found)
Lua itself — pinned by version and sha256 into `third_party/.cache`
(gitignored), then reused offline on later builds.
Override the defaults with make variables:
`LUA=auto|bundled|DIR`, `CURL=auto|DIR`, `FENNEL_LUA=PATH`, `PREFIX=DIR`,
`CACHE=DIR`, and `OFFLINE=1` (fetch nothing; fail if a source is not cached).
The pinned versions and the native object list live in the Makefile and must
track `nix/artifacts.nix`, which stays the source of truth.
The `checkPins` flake check (run by `nix flake check`, or `make check-pins`)
compares the Makefile's pinned versions against the flake's nixpkgs and fails on
drift; the native object list is guarded instead by `make check-portable`
failing to build.

The resulting binary links Lua, kubazip, lua-cjson, luafilesystem, LuaSocket,
termbox2, `fen_http`, `fen_process`, `fen_random`, and the embedded module ZIP statically,
keeping only libc, libm, libdl, and the host libcurl dynamic.
It is not the GLIBC-floor or musl-static artifact the Nix build produces; for
portable or release binaries, use Nix.
`fen ext build` native-rock support needs LuaRocks, which this build does not
embed; the core agent does not require it.

## Artifact status

Built binaries embed a git/build stamp in `fen.version`.
Run `fen --version` to see the distributed code identity, for example `fen a7ef7f5-dirty (nix, x86_64-linux)`.
The interactive `/status` panel shows the same version line.

| command | status | purpose |
| --- | --- | --- |
| `nix build` / `nix build .#fen` | distribution / canonical dev runtime | Single executable with embedded Lua archive and statically registered Fen native modules, linked for a GLIBC 2.17 floor on x86_64. |
| `nix build .#fenSingleStatic` | release artifact | Fully-static x86_64 musl executable with the same embedded Lua archive and Fen-owned native modules. |
| `nix build .#fen-linux-aarch64` | release artifact | Cross-built Linux aarch64 executable linked for a GLIBC 2.17 floor. |
| `nix build .#fen-linux-aarch64-musl-static` | release artifact | Cross-built fully-static Linux aarch64 musl executable. |
| `nix build .#fen-linux-armv7-gnueabihf` | release artifact | Cross-built Linux ARMv7 hard-float executable linked for a GLIBC 2.17 floor. |
| `nix build .#fen-linux-armv7-musleabihf-static` | release artifact | Cross-built fully-static Linux ARMv7 musl hard-float executable. |
| `nix build .#fen-linux-armv7-n900-musleabihf-static` | device-specific artifact | Fully-static ARMv7 musl hard-float artifact tuned for the Nokia N900 Cortex-A8 with Thumb-2 and NEON. |

## Releases

Pushing a version tag that matches `v*` runs `.github/workflows/release.yml`.
The workflow first runs release-targeted native checks (`fennelCheck` and
`tests`), then builds the supported Linux executables in parallel matrix jobs.
The x86_64 build job smoke-runs native artifacts with `--help` / `--version` and runs the artifact dependency checks.
Cross build jobs run the matching QEMU smoke, no-store-reference, and dynamic-dependency checks for each target.
Each build job uses the GitHub Actions-backed Nix cache, uploads a short-lived
binary artifact, and a final publish job downloads all binaries, creates
`SHA256SUMS`, and uploads the assets to the GitHub Release for that tag.

Release asset names are:

- `fen-<tag>-linux-x86_64`
- `fen-<tag>-linux-x86_64-musl-static`
- `fen-<tag>-linux-aarch64`
- `fen-<tag>-linux-aarch64-musl-static`
- `fen-<tag>-linux-armv7-gnueabihf`
- `fen-<tag>-linux-armv7-musleabihf-static`
- `fen-<tag>-linux-armv7-n900-musleabihf-static`
- `SHA256SUMS`

Maintainer flow:

```sh
git tag v0.1.0
git push origin v0.1.0
```

For a local preflight, run the same checks and builds manually:

```sh
nix build \
  .#checks.x86_64-linux.fennelCheck \
  .#checks.x86_64-linux.tests \
  .#checks.x86_64-linux.fenSmoke
nix build .#fen
nix build .#fenSingleStatic
nix build .#fen-linux-aarch64
nix build .#fen-linux-aarch64-musl-static
nix build .#fen-linux-armv7-gnueabihf
nix build .#fen-linux-armv7-musleabihf-static
nix build .#fen-linux-armv7-n900-musleabihf-static
```

Run `nix flake check` before tagging when you want the full CI surface,
including overlay/ext/no-store/dynamic-dependency checks and cross-QEMU smoke
checks. The tag workflow intentionally uses a narrower release gate so cold
GitHub runners do not spend the release job rebuilding every check. It also
parallelizes architecture builds to reduce wall-clock release time; total
compute is still dominated by custom static OpenSSL/curl/Lua builds unless the
Nix cache is warm.

## Compatibility and internal paths

| command/path | role |
| --- | --- |
| `make dev` | Convenience alias for `scripts/dev/fen-dev` using `FEN_BIN` or `fen` on `PATH`. |
| `make dev-nix` | Convenience alias for `nix build .#fen`, then `scripts/dev/fen-dev`. |
| `make test` | Convenience alias for `sh scripts/test/run-tests.sh`. |
| `make clean` | Remove generated local artifacts and Nix result symlinks. |
| `fen ext build <dir>` | Extension dependency build; builds the extension's single rockspec into `${XDG_DATA_HOME:-~/.local/share}/fen/rocks` or `FEN_ROCKS_TREE` using the bundled local-only LuaRocks runtime. |

Make is intentionally tiny: it keeps only the common dev/test/clean shortcuts.
Use Nix and scripts directly for the rest.

## Related issues

- #66 — production single-file executable with minimal dynamic dependencies.
- #63 — release workflow for Linux bundle artifacts.
- #68 — extension dependency resolution and `fen ext build` with bundled LuaRocks.
- #69 — canonicalize build, dev, and distribution workflows.


## Runtime artifact policy

Nix is the canonical reproducible build path. The public runtime artifact is the
production single-file binary from `nix build .#fen`; source-checkout
development uses that same binary through `scripts/dev/fen-dev` overlays.

Cross single-file binaries are exposed from x86_64 Linux as
`.#fen-linux-aarch64`, `.#fen-linux-armv7-gnueabihf`,
`.#fen-linux-aarch64-musl-static`, `.#fen-linux-armv7-musleabihf-static`,
and `.#fen-linux-armv7-n900-musleabihf-static`.

The default `.#fen` artifact is still the glibc-compatible single-file binary.
It embeds Fen's Lua module tree and Fen-owned native modules, and it statically links the bundled liblua, libzip, libcurl, OpenSSL, cjson, LuaSocket, termbox2, `fen_http`, `fen_process`, `fen_random`, and `lfs` pieces.
The x86_64, aarch64, and ARMv7 dynamic artifacts are built with Zig against a GLIBC 2.17 floor while keeping only the system loader, glibc, libm, libdl, and libpthread as dynamic dependencies.
This is a minimum-symbol-version policy for Fen's standalone executable, not a language-packaging compatibility tag.
For those targets, Lua, Fen-owned C, kubazip, OpenSSL, curl, and the final link all use the same old-glibc Zig target.
The N900-specific musl-static artifact passes GCC flags `-mcpu=cortex-a8 -mfpu=neon -mthumb` through the static toolchain.
Use the musl-static artifacts when carrying any dynamic glibc loader floor is undesirable.

`.#fenSingleStatic` is the stricter musl artifact.
It is linked with Nixpkgs `pkgsStatic`, has no ELF interpreter, has no dynamic `NEEDED` entries, and should not contain `/nix/store` references.
Use it on hosts where carrying a glibc runtime floor is undesirable.
HTTPS still needs CA certificate data from the target host, or an explicit `SSL_CERT_FILE` / `CURL_CA_BUNDLE` pointing at a PEM bundle.
External native Lua rocks are unsupported for the fully-static artifact; pure-Lua rocks may work through the normal extension rocks tree, while native-rock escape hatches remain tracked separately in #70.

Current musl-static target status:

| package | target ABI | status |
| --- | --- | --- |
| `.#fenSingleStatic` | `linux-x86_64-musl-static` | supported and checked by `singleStaticSmoke`, `singleStaticNativeSmoke`, `singleStaticNoStoreRefs`, and `singleStaticNoDynamicDeps`. |
| `.#fen-linux-aarch64-musl-static` | `linux-aarch64-musl-static` | cross-built from x86_64 Linux and checked by QEMU smoke, no-store-ref, and no-dynamic-dependency checks. |
| `.#fen-linux-armv7-musleabihf-static` | `linux-armv7-musleabihf-static` | cross-built from x86_64 Linux and checked by QEMU smoke, no-store-ref, and no-dynamic-dependency checks. |
| `.#fen-linux-armv7-n900-musleabihf-static` | `linux-armv7-n900-musleabihf-static` | N900-tuned static variant cross-built from x86_64 Linux and checked by QEMU smoke, no-store-ref, and no-dynamic-dependency checks. |

Docker smoke helpers:

- `nix run .#dockerSmoke` builds/loads a scratch-based Docker image and runs
  `fen --help`.
- `nix run .#loadDockerDev` loads the same image as `fen:dev`.

The old non-Nix `fen-dist.tar.gz` target, public wrapped Lua package, portable
Nix runtime tarball, and source-checkout `bin/fen` launcher assembled directly
from generated `dist/` trees have been retired. Use `scripts/dev/fen-dev` for checkout
development and `nix build .#fen` for the runtime artifact. No release artifact
should be cut from a local generated-tree path.
