# Distribution and workflow status

fen is consolidating around one canonical path: Nix builds the runtime and
release artifacts, while the single-file binary plus source overlays drives
normal development.

## Canonical development

Use the single-file runtime from `.#fen` and the checkout wrapper:

```sh
nix build .#fen
FEN_BIN=$PWD/result/bin/fen scripts/fen-dev
```

`scripts/fen-dev` prepends package source roots to `FEN_DEV_PATH` and the flat
first-party extension root to `FEN_EXTENSION_ROOT`. The embedded Fennel compiler
loads `.fnl` directly, so edits are visible after `/reload` without generated
package output.

Fast local checks remain useful:

```sh
fennel scripts/fennel-check.fnl
make test
```

The reproducible CI surface is:

```sh
nix flake check
```

## Artifact status

| command | status | purpose |
| --- | --- | --- |
| `nix build` / `nix build .#fen` | distribution / canonical dev runtime | Single executable with embedded Lua archive and statically registered Fen native modules. |
| `nix build .#fen-linux-aarch64` | release artifact | Cross-built Linux aarch64 executable. |
| `nix build .#fen-linux-armv7-gnueabihf` | release artifact | Cross-built Linux ARMv7 hard-float executable. |

## Releases

Pushing a version tag that matches `v*` runs `.github/workflows/release.yml`.
The workflow runs release-targeted native checks (`fennelCheck`, `tests`, and
`fenSmoke`), then builds the supported Linux executables in parallel matrix
jobs. Each build job uses the GitHub Actions-backed Nix cache, uploads a
short-lived binary artifact, and a final publish job downloads all binaries,
creates `SHA256SUMS`, and uploads the assets to the GitHub Release for that
tag.

Release asset names are:

- `fen-<tag>-linux-x86_64`
- `fen-<tag>-linux-aarch64`
- `fen-<tag>-linux-armv7-gnueabihf`
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
nix build .#fen-linux-aarch64
nix build .#fen-linux-armv7-gnueabihf
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
| `make dev` | Convenience alias for `scripts/fen-dev` using `FEN_BIN` or `fen` on `PATH`. |
| `make dev-nix` | Convenience alias for `nix build .#fen`, then `scripts/fen-dev`. |
| `make test` | Convenience alias for `sh scripts/run-tests.sh`. |
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
development uses that same binary through `scripts/fen-dev` overlays.

Cross single-file binaries are exposed from x86_64 Linux as
`.#fen-linux-aarch64` and `.#fen-linux-armv7-gnueabihf`.

Docker smoke helpers:

- `nix run .#dockerSmoke` builds/loads a scratch-based Docker image and runs
  `fen --help`.
- `nix run .#loadDockerDev` loads the same image as `fen:dev`.

The old non-Nix `fen-dist.tar.gz` target, public wrapped Lua package, portable
Nix runtime tarball, and source-checkout `bin/fen` launcher assembled directly
from generated `dist/` trees have been retired. Use `scripts/fen-dev` for checkout
development and `nix build .#fen` for the runtime artifact. No release artifact
should be cut from a local generated-tree path.
