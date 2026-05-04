# Distribution and workflow status

fen is consolidating around one canonical path: Nix builds the runtime and
release artifacts, while the single-file binary plus source overlays drives
normal development.

## Canonical development

Use the single-file runtime from `.#fen` and the checkout wrapper:

```sh
nix build .#fen
FEN_BIN=$PWD/result/bin/fen bin/fen-dev
```

`bin/fen-dev` passes `--dev-path` roots for package sources and
`--extension-root extensions` for flat first-party extensions. The
embedded Fennel compiler loads `.fnl` directly, so edits are visible after
`/reload` without generated package output.

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
The workflow runs `nix flake check`, builds the supported Linux executables,
and uploads them to the GitHub Release for that tag with a `SHA256SUMS` file.

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
nix flake check
nix build .#fen
nix build .#fen-linux-aarch64
nix build .#fen-linux-armv7-gnueabihf
```

## Compatibility and internal paths

| command/path | role |
| --- | --- |
| `make dev` | Convenience alias for `nix build .#fen`, then `bin/fen-dev`. |
| `make test` | Convenience alias for `sh scripts/run-tests.sh`. |
| `make clean` | Remove generated local artifacts and Nix result symlinks. |
| `fen ext build <dir>` | Extension dependency build | Builds the extension's single rockspec into `${XDG_DATA_HOME:-~/.local/share}/fen/rocks` or `FEN_ROCKS_TREE` using the bundled local-only LuaRocks runtime. |

Make is intentionally tiny: it keeps only the common dev/test/clean shortcuts.
Use Nix and scripts directly for the rest.

## Related issues

- #66 — production single-file executable with minimal dynamic dependencies.
- #63 — release workflow for Linux bundle artifacts.
- #68 — extension dependency resolution and `fen ext build` with bundled LuaRocks.
- #69 — canonicalize build, dev, and distribution workflows.
