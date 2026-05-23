# Single-file executable

`nix build .#fen` builds the single-file `fen` executable at `result/bin/fen`;
`make fen` builds the same binary against the host toolchain (see
[`distribution.md`](distribution.md#building-without-nix)).
It is also the canonical development runtime for source-checkout work: pair it
with `scripts/fen-dev`, edit `.fnl`, and use `/reload` without regenerating package
Lua trees.

The binary is a native launcher that statically links Lua 5.4, kubazip, and the
project's other native modules (cjson, `fen_http`, `fen_process`, `fen_random`,
termbox2, lfs); see [`distribution.md`](distribution.md) for the full link and
runtime-dependency breakdown across the Nix and `make fen` builds.
The build creates a deterministic ZIP from the packaged `share/lua/5.4` module tree,
appends that ZIP to the launcher ELF, and installs `package.searchers` entries
that load Lua and Fennel modules from the embedded archive.

Module lookup maps Lua names to archive paths:

- `fen.main` -> `fen/main.lua`
- `fen.core.agent` -> `fen/core/agent.lua`
- `fen.core.extensions.events` -> `fen/core/extensions/events.lua`
- `fen.core.extensions.register.tool` ->
  `fen/core/extensions/register/tool.lua`

The current acceptance smoke is:

```sh
nix build .#fen
./result/bin/fen --help
nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).fenSmoke
```

On x86_64 Linux, cross-compiled prototype artifacts are also exposed:

```sh
nix build .#fen-linux-aarch64
nix build .#fen-linux-armv7-gnueabihf
nix build .#checks.x86_64-linux.fenSmoke-linux-aarch64
nix build .#checks.x86_64-linux.fenSmoke-linux-armv7-gnueabihf
```

`fen --help` is intentionally lazy-loaded so it does not require JSON, HTTP,
TUI, or provider modules before printing usage.

## Searcher precedence

`package.searchers` is set up by the launcher before `(require :fen.main)` runs,
in this order (lower index wins):

1. `package.preload` — standard slot, used by tests for module stubbing.
2. `dev-path-fennel` — compiles `.fnl` files found via `--dev-path` /
   `FEN_DEV_PATH` (consults `package.path` after `prepend_dev_paths` mutates it
   to put dev-path roots ahead of the floor).
3. `flat-extension` — installed via `fen.util.flat_extensions.install!` when
   `--extension-root` (or `FEN_EXTENSION_ROOT`) is set; resolves
   `fen.extensions.<snake>[.<rest>]` to `<extension-root>/<kebab>/<rest>.fnl`
   for flat-layout extensions discovered by walking each root.
4. Standard Lua searchers — `package.path` (`?.lua`/`?/init.lua`) and the C
   loaders. Includes whatever the user set in `LUA_PATH` / `LUA_CPATH`.
5. `embedded-zip` — loads `.lua` from the appended archive (the production
   floor; what runs without any overlay flags).
6. `embedded-fennel` — compiles `.fnl` from the appended archive (used when
   the embedded module is shipped as Fennel rather than precompiled Lua).

In short: dev-path overlays beat the embedded archive; `LUA_PATH` extensions
beat the embedded archive but lose to dev-path; `package.preload` always wins.

## Development workflow

The launcher is the primary dev affordance: ship one binary, redirect module
resolution to a source checkout via overlay flags. `.fnl` edits are visible
after `/reload` without rebuilding the binary.

Two flags, equivalent env vars:

- `--dev-path <dir>` (repeatable), `FEN_DEV_PATH=<dir>[:<dir>...]` —
  Lua-module overlay root. `<dir>/foo/bar.fnl` resolves the module `foo.bar`.
  Use for rock-shaped substrate: `packages/core/src`, `packages/util/src`,
  and `packages/fen/src`.
- `--extension-root <dir>` (repeatable), `FEN_EXTENSION_ROOT=<dir>[:<dir>...]` —
  manifest-walking root for flat-layout extensions. Each `<dir>/<kebab>/`
  with a `manifest.fnl` is a discoverable extension; `fen.util.flat_extensions`
  bridges `require :fen.extensions.<snake>...` back to the flat source.

CLI flags are stripped from `argv` by the launcher before `fen.main` sees them;
env vars do not affect `argv`. CLI values are applied first, then env values.
Extension roots are exposed to the loader as trusted first-party flat overlays,
separate from `FEN_EXTENSIONS_PATH` user roots.

The `scripts/fen-dev` wrapper drives the whole checkout from a single binary:

```sh
nix build .#fen
FEN_BIN=$PWD/result/bin/fen scripts/fen-dev

# Equivalent one-liner:
FEN_BIN=$(nix build .#fen --print-out-paths)/bin/fen ./scripts/fen-dev
```

It prepends every workspace `src/` tree to `FEN_DEV_PATH` and `extensions` to
`FEN_EXTENSION_ROOT`. From there, edit any `.fnl`, run `/reload` from the TUI,
see the change without rebuilding the binary.

Production users without overlay flags fall through to the embedded archive
unchanged. The `fenOverlaySmoke` flake check builds the binary and verifies
module overlays, extension-root loading, native module lookup, and the
`scripts/fen-dev` wrapper against fixtures / checkout source.

## Notes and limitations

- The native modules (cjson, `fen_http`, `fen_process`, `fen_random`, termbox2,
  lfs) are statically registered into the launcher, so the embedded archive
  carries only Lua/Fennel source. See [`distribution.md`](distribution.md) for
  which libraries each build links statically versus dynamically (the Nix
  artifacts reach a GLIBC floor or full musl-static; the `make fen` binary keeps
  the host libcurl dynamic).
- Embedded modules do not have ordinary filesystem paths. `/reload`
  fingerprinting uses `package.searchpath`, so a module served from the
  embedded archive (no overlay) is treated as distribution-time fixed.
  Hot-reload picks up `.fnl` edits when the same module is shadowed by a
  `--dev-path` or `--extension-root` overlay (see "Development workflow"
  above) — the searcher resolves the overlay first, fingerprinting reads
  the overlay file, and `/reload` re-requires through it.

## Inspecting the archive

Standard ZIP tools can inspect the appended archive, with a warning about the
ELF prefix:

```sh
unzip -l result/bin/fen | head
```
