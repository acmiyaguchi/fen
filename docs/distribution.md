# Distribution

Nix is the canonical, reproducible build and the source of every release
artifact.
The public runtime artifact is the production single-file binary from
`nix build .#fen`; source-checkout development uses that same binary through
`scripts/dev/fen-dev` overlays (see [`development.md`](development.md)).

Built binaries embed a git/build stamp in `fen.version`.
Run `fen --version` to see the distributed code identity, for example
`fen a7ef7f5-dirty (nix, x86_64-linux)`; the interactive `/status` panel shows
the same line.

## Nix artifacts

| Nix attribute | Target | Linking | Release asset (`fen-<tag>-…`) | Checks |
| --- | --- | --- | --- | --- |
| `.#fen` | x86_64 Linux musl | fully static | `linux-x86_64-musl-static` | `fenSmoke`, `fenNoStoreRefs`, `fenNoDynamicDeps` (canonical dev runtime + default public artifact) |
| `.#fenSingleStatic` | x86_64 Linux musl | fully static | alias of `.#fen` | same as `.#fen` |
| `.#fen-linux-aarch64-musl-static` | aarch64 Linux musl | fully static | `linux-aarch64-musl-static` | QEMU smoke, no-store-ref, no-dynamic-dependency |
| `.#fen-linux-armv7-musleabihf-static` | ARMv7 hard-float musl | fully static | `linux-armv7-musleabihf-static` | QEMU smoke, no-store-ref, no-dynamic-dependency |
| `.#fen-linux-armv7-n900-musleabihf-static` | ARMv7 N900 (Cortex-A8 NEON/Thumb-2) musl | fully static | `linux-armv7-n900-musleabihf-static` | QEMU smoke, no-store-ref, no-dynamic-dependency |

Every artifact embeds Fen's Lua module tree and Fen-owned native modules and
statically links the bundled liblua, libzip, libcurl, OpenSSL, cjson, LuaSocket,
termbox2, `fen_http`, `fen_process`, `fen_random`, and `lfs` pieces.

The Linux runtime is a single fully-static musl build for every architecture.
The binaries have no ELF interpreter, no dynamic `NEEDED` entries, and no
`/nix/store` references, so they run on any Linux of the matching architecture
without a libc runtime floor.
HTTPS still needs CA certificate data from the target host, or an explicit
`SSL_CERT_FILE` / `CURL_CA_BUNDLE` pointing at a PEM bundle.
The N900 variant passes `-mcpu=cortex-a8 -mfpu=neon -mthumb` through Fen's
launcher and bundled native module compiles, while reusing the generic ARMv7
third-party static dependency closure.

Extensions depend on pure-Lua rocks only.
Static linking has no dynamic loader, so external native Lua rocks (`.so`
modules) cannot be loaded; Fen's own native modules are embedded in the binary.
Supply pure-Lua dependencies through the extension rocks tree (`LUA_PATH` /
`--dev-path`).

Cross artifacts are exposed only from x86_64 Linux.

## Docker scratch image

The flake exposes a tiny scratch image containing the static `fen` binary, BusyBox, CA certificates, and a writable `/tmp`.
It is useful for smoke tests or trying Fen on a host with Docker without installing the binary.

```sh
nix run .#dockerRun -- --help
OPENAI_API_KEY=... nix run .#dockerRun -- --print "say hi"
nix run .#dockerShell
```

`dockerRun` builds and loads `.#scratchImage`, tags it as `fen:dev`, mounts the current directory at `/workspace`, sets `/workspace` as the container working directory, and passes common provider environment variables through.
Make aliases are available when you prefer the Makefile frontend:

```sh
make docker-run-nix ARGS='--help'
make docker-shell-nix
make docker-smoke-nix
```

For manual image handling, run `nix run .#loadDockerDev` or `nix build .#scratchImage && docker load < result`.
The image entrypoint is `/bin/fen`, so arguments after the image name are Fen arguments.
Container state defaults to `/tmp`; mount config/state directories yourself if you want persistence.

## Single-file binary format

The binary is a native launcher that statically registers the Fen-owned native
modules (cjson, LuaSocket core, `fen_http`, `fen_process`, `fen_random`,
termbox2, lfs), then appends a deterministic ZIP of the packaged
`share/lua/5.4` module tree to the launcher ELF.
At startup it installs `package.searchers` entries that load Lua and Fennel
modules from that embedded archive, so the archive carries only Lua/Fennel
source.
`fen --help` is intentionally lazy-loaded so it does not require JSON, HTTP, TUI,
or provider modules before printing usage.

Module lookup maps Lua names to archive paths:

- `fen.main` → `fen/main.lua`
- `fen.core.agent` → `fen/core/agent.lua`
- `fen.core.extensions.register.tool` → `fen/core/extensions/register/tool.lua`

### Searcher precedence

`package.searchers` is set up by the launcher before `(require :fen.main)` runs,
in this order (lower index wins):

1. `package.preload` — standard slot, used by tests for module stubbing.
2. `dev-path-fennel` — compiles `.fnl` files found via `--dev-path` /
   `FEN_DEV_PATH` (consults `package.path` after `prepend_dev_paths` puts
   dev-path roots ahead of the floor).
3. `flat-extension` — installed when `--extension-root` / `FEN_EXTENSION_ROOT`
   is set; resolves `fen.extensions.<snake>[.<rest>]` to
   `<extension-root>/<kebab>/<rest>.fnl` for flat-layout extensions.
4. Standard Lua searchers — `package.path` (`?.lua`/`?/init.lua`) and the C
   loaders, including whatever the user set in `LUA_PATH` / `LUA_CPATH`. The
   fully-static release binary has no dynamic loader, so the C loaders resolve
   nothing; only the pure-Lua `package.path` half is reachable in practice.
5. `embedded-zip` — loads `.lua` from the appended archive (the production
   floor; what runs without any overlay flags).
6. `embedded-fennel` — compiles `.fnl` from the appended archive (when the
   embedded module ships as Fennel rather than precompiled Lua).

In short: dev-path overlays beat the embedded archive; `LUA_PATH` extensions
beat the embedded archive but lose to dev-path; `package.preload` always wins.

### Dev overlays

Two repeatable flags redirect module resolution to a source checkout, each with
an equivalent env var:

- `--dev-path <dir>` / `FEN_DEV_PATH=<dir>[:<dir>…]` — Lua-module overlay root;
  `<dir>/foo/bar.fnl` resolves the module `foo.bar`. Used for rock-shaped
  substrate (`packages/core/src`, `packages/util/src`, `packages/fen/src`).
- `--extension-root <dir>` / `FEN_EXTENSION_ROOT=<dir>[:<dir>…]` —
  manifest-walking root for flat-layout extensions; each `<dir>/<kebab>/` with a
  `manifest.fnl` is discoverable, and `fen.util.flat_extensions` bridges
  `require :fen.extensions.<snake>…` back to the flat source.

CLI flags are stripped from `argv` by the launcher before `fen.main` sees them;
env vars do not affect `argv`. CLI values apply first, then env values.
Extension roots are exposed to the loader as trusted first-party flat overlays,
separate from `FEN_EXTENSIONS_PATH` user roots.
`scripts/dev/fen-dev` wires all of this up for checkout work; see
[`development.md`](development.md) for the iteration loop.
Production users without overlay flags fall through to the embedded archive
unchanged.
The `fenOverlaySmoke` flake check verifies module overlays, extension-root
loading, native-module lookup, and the wrapper against fixtures.

Embedded modules have no ordinary filesystem path. `/reload` fingerprinting uses
`package.searchpath`, so a module served straight from the embedded archive is
treated as distribution-time fixed; hot reload picks up `.fnl` edits only when
the same module is shadowed by a `--dev-path` / `--extension-root` overlay.

Standard ZIP tools can inspect the appended archive, with a warning about the
ELF prefix:

```sh
unzip -l result/bin/fen | head
```

## Building without Nix

For people who do not have Nix, `make fen` produces the same single-file binary
by linking against the host's Lua and libcurl instead.
There is no separate `./configure` step: the Makefile probes the toolchain and
fetches third-party sources itself, only when a portable goal is the make goal
(so `make test` and friends never shell out to pkg-config or the network).
This path is a convenience, not a release path: its binaries are not the
published artifacts and carry a `make` source stamp rather than `nix`.

```sh
make fen                    # probe toolchain, fetch sources, compile + embed -> build/fen
make dev-portable           # build build/fen, then run the checkout with source overlays
sudo make install           # optional: install to $PREFIX/bin (default /usr/local)
make check-portable         # build build/fen and smoke --version/--help/modules
make check-portable-docker  # build+smoke the whole apt path in a clean Debian container
```

`make check-portable-docker` (needs Docker, set `DOCKER=podman` to switch) runs
the documented `apt install … && make fen` flow on `debian:stable-slim` against
a read-only copy of the checkout, fetching sources over the network like a real
user.
It cannot run under `nix flake check` — that sandbox has no Docker and no
network — so it is a standalone CI/maintainer check.

The host must provide a C compiler, `pkg-config` (to locate system Lua and
libcurl), the `fennel` and `zip` CLIs, a Lua 5.4 interpreter (used only to build
`fennel.lua`), and system libcurl with headers.
On Debian/Raspberry Pi OS that is roughly
`apt install build-essential pkg-config libcurl4-openssl-dev liblua5.4-dev lua5.4 zip`
plus `fennel` (via `luarocks install fennel`).

`make fen` resolves the sources the Nix build normally fetches — kubazip,
lua-cjson, luafilesystem, LuaSocket, fennel, dkjson, and (when no system Lua 5.4
is found) Lua itself — pinned by version and sha256 into `third_party/.cache`
(gitignored), then reused offline on later builds.
Override defaults with make variables: `LUA=auto|bundled|DIR`, `CURL=auto|DIR`,
`FENNEL_LUA=PATH`, `PREFIX=DIR`, `CACHE=DIR`, and `OFFLINE=1` (fetch nothing;
fail if a source is not cached).
The pinned versions and per-object compile flags live in the Makefile and must
track `nix/artifacts.nix`, which stays the source of truth.
The LuaSocket C module list is no longer duplicated: both paths read it from
`scripts/build/luasocket-c-modules.txt` (one source of truth), so adding or
dropping a LuaSocket module updates the Nix and non-Nix builds together.
Both build paths stage the embedded Lua module tree through
`scripts/build/package-lua-tree.sh`: Nix supplies store paths for Fennel,
dkjson, LuaSocket, and LuaRocks, while `make fen` supplies cached/downloaded
paths and intentionally omits LuaRocks to keep the random-system core-agent
build small.
The `.fnl`->`.lua` compile rules (file walk, excludes, source-to-output
mapping, generated skills data) live once in `fen.core.extensions.build`.
`scripts/build/fennel-build.fnl` loads that module with bare `fennel` for the
workspace and per-rock `--lrbuild` builds, and `fen ext build` requires the same
embedded module to compile in process; the fennel compiler is the shared
bootstrap floor, never a built `fen` binary.
Every rockspec `build_command` is a one-line call into `fennel-build.fnl`
instead of a copy-pasted compile heredoc.
The `checkPins` flake check (run by `nix flake check`, or `make check-pins`)
fails on version drift; the native object list is guarded by `make
check-portable` failing to build.

The resulting binary links Lua, kubazip, lua-cjson, luafilesystem, LuaSocket,
termbox2, `fen_http`, `fen_process`, `fen_random`, and the embedded module ZIP
statically, keeping only libc, libm, libdl, and the host libcurl dynamic.
It is not the musl-static artifact the Nix build produces; for portable or
release binaries, use Nix.
`fen ext build` native-rock support needs LuaRocks, which this build does not
embed; the core agent does not require it.

## Install script

`scripts/install.sh` is a POSIX `sh` one-liner installer for the prebuilt
release binaries, served from the docs site (the `docs-publish` target copies it
to `dist/docs/install.sh`):

```sh
curl -fsSL https://acmiyaguchi.github.io/fen/install.sh | sh
```

Because the release artifacts are fully-static musl binaries with no toolchain to
bootstrap, the script only resolves the target, downloads the matching asset,
verifies it, and drops it on `PATH` — there is no managed toolchain like
rustup/uv. Once installed, the binary can refresh itself in place with
`fen update` (see below).

What it does:

- Detects the asset from `uname -s`/`uname -m`: `linux-x86_64-musl-static`,
  `linux-aarch64-musl-static`, or the generic `linux-armv7-musleabihf-static`.
  The N900-tuned build is cortex-a8-specific and is not auto-selected.
- Resolves the latest tag by following the `releases/latest` redirect (no GitHub
  API, so no `jq` and no unauthenticated rate limit).
- Downloads `fen-<tag>-<asset>` plus `SHA256SUMS` and verifies the checksum with
  `sha256sum`/`shasum` before installing.
- Installs to `$HOME/.local/bin/fen` and warns if that directory is not on
  `PATH`.

Environment overrides: `FEN_VERSION=vX.Y.Z` pins a tag, `FEN_BIN_DIR` changes the
install directory, and `FEN_ARCH=<asset-slug>` forces an asset (e.g.
`linux-armv7-n900-musleabihf-static` for the N900-tuned build).

Caveats: the prebuilt binaries are **Linux-only** — on other platforms build
from source (`nix build .#fen` or `make fen`). HTTPS at runtime still needs host
CA certificates or `SSL_CERT_FILE`/`CURL_CA_BUNDLE` as noted above.

Audit-conscious users can skip the script and download directly:

```sh
tag=v0.6.2; asset=linux-x86_64-musl-static
base="https://github.com/acmiyaguchi/fen/releases/download/$tag"
curl -fsSLO "$base/fen-$tag-$asset"
curl -fsSL "$base/SHA256SUMS" | grep "fen-$tag-$asset" | sha256sum -c -
install -m 0755 "fen-$tag-$asset" ~/.local/bin/fen
```

## Self-update (`fen update`)

`fen update` replaces the running single-file binary with the latest GitHub
release. Because the binary is a C launcher with an appended zip, an update is a
whole-file swap, not a partial patch. The flow lives in `fen.update`
(`packages/fen/src/fen/update.fnl`) and reuses in-tree primitives only — no
system `curl`/`sha256sum` dependency:

- Refuses anything that is not a tagged release artifact: source/dev checkouts,
  untagged local builds, and luarocks installs all print guidance and exit
  non-zero. Only `nix`/`make` builds stamped with a `vX.Y.Z` version proceed.
- Detects the asset slug from `uname` (same mapping as `install.sh`; honors the
  `FEN_ARCH` override for the N900-tuned build).
- Queries `…/releases/latest` via the GitHub API and compares `tag_name` to the
  running version; an exact match prints "already up to date" and exits 0.
- Downloads `fen-<tag>-<asset>` and `SHA256SUMS` through `fen.util.http`
  (following the asset's CDN redirect manually, since the native transport does
  not follow redirects), verifies the SHA-256 with the pure-Lua
  `fen.util.sha256`, then atomically renames the new binary over the running one
  (the live process keeps its old inode, exactly like the installer's `mv -f`).
- Refuses gracefully when the install directory is not writable (e.g. a
  read-only Nix store path) — the original binary is left untouched.

The launcher (`fen.c`) surfaces the resolved executable path as `arg.exe` so the
update can target the right file even when invoked as a bare name found on
`PATH`. Restart fen after a successful update to load the new code.

## Releases

Pushing a version tag matching `v*` runs `.github/workflows/release.yml`.
The workflow first runs release-targeted native checks (`fennelCheck` and
`tests`), then builds the supported Linux executables in parallel
architecture-family matrix jobs.
The x86_64 job smoke-runs the default static artifact with `--help` / `--version`
and runs the no-store-reference and no-dynamic-dependency checks; the aarch64
job builds and checks that cross artifact; the ARMv7-family job builds the
generic and N900 artifacts together so Nix can reuse the generic ARMv7 static
dependency closure before running each matching QEMU smoke, no-store-reference,
and no-dynamic-dependency check.
A final publish job downloads all binaries, creates `SHA256SUMS`, and uploads
the assets (named `fen-<tag>-<asset>` per the matrix above, plus `SHA256SUMS`)
to the GitHub Release for that tag.

The `VERSION` file at the repo root is the source of truth for the release
version.
Pure flake evaluation cannot see git tags through `self`, so non-CI `nix build`
reads `VERSION` (producing `vX.Y.Z`, or `vX.Y.Z-dirty` for a dirty tree), while
the release workflow overrides it with `FEN_VERSION` from `git describe`.
The release job fails fast if `v$(cat VERSION)` does not match the pushed tag,
so the file and the tag can never drift silently.

Because `main` is protected, a release is two phases: the `VERSION` bump lands
through a PR, then the tag is pushed at the merged commit to trigger the
workflow.
`scripts/release.sh` drives both and enforces the VERSION-matches-tag invariant
locally before anything is pushed (bare invocations are dry runs).

Maintainer flow:

```sh
# 1. Prepare: branch off origin/main, bump VERSION, commit, push, open the PR.
scripts/release.sh prepare 0.15.0 --push --pr   # or: make release-prepare VERSION=0.15.0 PUSH=1

# 2. Merge the PR, then sync main locally.
git checkout main && git pull

# 3. Tag: verify main is in sync and VERSION matches, then push the tag.
scripts/release.sh tag --push                   # or: make release-tag PUSH=1
```

Drop `--push`/`PUSH=1` (or the `--pr` flag) for a dry run that stops before
touching the remote.
Pass `--preflight` to `scripts/release.sh tag` to build the release checks and
`.#fen` locally before tagging.
The underlying tag push is all the workflow needs; the manual equivalent is:

```sh
git tag v0.15.0
git push origin v0.15.0
```

For a local preflight, build the same checks and artifacts manually.
Pass all artifact attributes to one `nix build` invocation so Nix can share the
cross toolchains and static dependency builds across targets:

```sh
nix build --no-link --print-out-paths \
  .#checks.x86_64-linux.fennelCheck \
  .#checks.x86_64-linux.tests \
  .#checks.x86_64-linux.fenSmoke
nix build --no-link --print-out-paths .#fen \
  .#fen-linux-aarch64-musl-static \
  .#fen-linux-armv7-musleabihf-static \
  .#fen-linux-armv7-n900-musleabihf-static
# or, for just the three cross artifacts:
make build-cross-nix
```

Run `nix flake check` before tagging for the full CI surface, including
overlay/ext/no-store/dynamic-dependency and cross-QEMU smoke checks. The tag
workflow uses a narrower release gate so cold runners do not rebuild every
check, and parallelizes architecture families. Cold cross builds are still
dominated by the target musl toolchains plus the custom static OpenSSL/curl/Lua
builds, but Fen's curl package disables unused protocols/features before
dependency selection and the N900 target reuses the generic ARMv7 third-party
dependency closure in the local preflight and release ARMv7-family job.

## Docker smoke

- `nix run .#dockerSmoke` builds/loads a scratch-based Docker image and runs
  `fen --help`.
- `nix run .#loadDockerDev` loads the same image as `fen:dev`.
