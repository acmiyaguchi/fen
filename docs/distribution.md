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
`/reload` without `make dist-tree` or generated package `dist/` trees.

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
| `make legacy-dist` | legacy compatibility | Lightweight tarball from generated package `dist/` trees; requires system Lua/rocks on the target. |

Until #66 embeds or statically registers the required native modules for normal
operation, the portable Nix tarball remains the stable release artifact. Once
#66 and #63 land, docs should make the production single-file binary the first
artifact users see.

## Compatibility and internal paths

| command/path | role |
| --- | --- |
| `make dist-tree` | Generates package `dist/` trees and native `.so` modules for the POSIX launcher / current package plumbing. Not required for source-checkout development under `bin/fen-dev`. |
| `bin/fen` | POSIX launcher over generated `dist/` trees and local rocks. Compatibility path while single-file distribution matures. |
| `make build` | Convenience alias for `nix build .#fenSingle`. |
| `make dist` | Convenience alias for `nix build .#dist`. |
| `make install-local` | Installs checked-in rockspecs to `./lua_modules` for local LuaRocks smoke testing. |
| `luarocks make` | Package/extension implementation detail. User-facing extension dependency builds are planned as `fen ext build <dir>` in #68. |

Long term, Make should either disappear or remain a thin convenience wrapper
around the canonical Nix/script entry points. The current Makefile is already in
that shape: Nix calls scripts directly, while Make forwards canonical artifact
builds to Nix and compatibility tasks to scripts.

## Related issues

- #66 — production single-file executable with minimal dynamic dependencies.
- #63 — release workflow for Linux bundle artifacts.
- #68 — extension dependency resolution and `fen ext build` with bundled LuaRocks.
- #69 — canonicalize build, dev, and distribution workflows.
