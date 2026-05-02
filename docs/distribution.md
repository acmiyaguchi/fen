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
| `nix build` / `nix build .#fen` | distribution / canonical dev runtime | Single executable with embedded Lua archive and statically registered Fen native modules. |

## Compatibility and internal paths

| command/path | role |
| --- | --- |
| `make build` | Convenience alias for `nix build .#fen`. |
| `fen ext build <dir>` | Extension dependency build | Builds the extension's single rockspec into `${XDG_DATA_HOME:-~/.local/share}/fen/rocks` or `FEN_ROCKS_TREE` using the bundled local-only LuaRocks runtime. |

Long term, Make should either disappear or remain a thin convenience wrapper
around the canonical Nix/script entry points. The current Makefile is already in
that shape: Nix owns artifacts, while Make forwards common commands to Nix or
small scripts.

## Related issues

- #66 — production single-file executable with minimal dynamic dependencies.
- #63 — release workflow for Linux bundle artifacts.
- #68 — extension dependency resolution and `fen ext build` with bundled LuaRocks.
- #69 — canonicalize build, dev, and distribution workflows.
