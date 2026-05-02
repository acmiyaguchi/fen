# Distribution and workflow status

fen is consolidating around one canonical path: Nix builds the runtime and
release artifacts, while the single-file binary plus source overlays drives
normal development.

## Canonical development

Use the single-file runtime from `.#fenSingle` and the checkout wrapper:

```sh
nix build .#fenSingle
FEN_BIN=$PWD/result/bin/fen bin/fen-dev
```

`bin/fen-dev` passes `--dev-path` roots for package sources and
`--extension-root packages/extensions` for flat first-party extensions. The
embedded Fennel compiler loads `.fnl` directly, so edits are visible after
`/reload` without generated package output.

Fast local checks remain useful:

```sh
make fennel-check
make test
```

The reproducible CI surface is:

```sh
nix flake check
```

## Artifact status

| command | status | purpose |
| --- | --- | --- |
| `nix build .#fenSingle` | preferred future distribution / canonical dev runtime | Single executable with embedded Lua archive. Production hardening is tracked by #66. |
| `nix build` | current Nix package | Runnable Nix package at `result/bin/fen`. |
| `nix build .#dist` | current portable release baseline | Linux tarball assembled from the Nix runtime closure. Release automation is tracked by #63. |

Until #66 embeds or statically registers the required native modules for normal
operation, the portable Nix tarball remains the stable release artifact. Once
#66 and #63 land, docs should make the production single-file binary the first
artifact users see.

## Compatibility and internal paths

| command/path | role |
| --- | --- |
| `make build` | Convenience alias for `nix build .#fenSingle`. |
| `make dist` | Convenience alias for `nix build .#dist`. |
| `fen ext build <dir>` | Extension dependency build | Builds the extension's single rockspec into `${XDG_DATA_HOME:-~/.local/share}/fen/rocks` or `FEN_ROCKS_TREE`. Currently shells to system LuaRocks; bundled LuaRocks is the remaining #68 phase. |
| `luarocks make` | Package/extension implementation detail | Normal users should prefer `fen ext build <dir>`. Maintainers can use `sh scripts/install-local-rocks.sh` as an internal rockspec smoke when needed. |

Long term, Make should either disappear or remain a thin convenience wrapper
around the canonical Nix/script entry points. The current Makefile is already in
that shape: Nix owns artifacts, while Make forwards common commands to Nix or
small scripts.

## Related issues

- #66 — production single-file executable with minimal dynamic dependencies.
- #63 — release workflow for Linux bundle artifacts.
- #68 — extension dependency resolution and `fen ext build` with bundled LuaRocks.
- #69 — canonicalize build, dev, and distribution workflows.
