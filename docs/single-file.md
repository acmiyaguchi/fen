# Single-file executable prototype

`nix build .#fenSingle` builds a Linux prototype at `result/bin/fen`.
This is the canonical development runtime for source-checkout work: pair it
with `bin/fen-dev`, edit `.fnl`, and use `/reload` without regenerating package
Lua trees. The production single-file artifact is finished under #66.

The prototype is a native launcher statically linked to Lua 5.4 and kubazip.
The build creates a deterministic ZIP from the packaged `share/lua/5.4` module tree,
appends that ZIP to the launcher ELF, and installs `package.searchers` entries
that load Lua and Fennel modules from the embedded archive.

Module lookup maps Lua names to archive paths:

- `fen.main` -> `fen/main.lua`
- `fen.core.agent` -> `fen/core/agent.lua`
- `fen.core.extensions` -> `fen/core/extensions.lua` or
  `fen/core/extensions/init.lua`

The current acceptance smoke is:

```sh
nix build .#fenSingle
./result/bin/fen --help
nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).singleSmoke
```

On x86_64 Linux, cross-compiled prototype artifacts are also exposed:

```sh
nix build .#fenSingle-linux-aarch64
nix build .#fenSingle-linux-armv7-gnueabihf
nix build .#checks.x86_64-linux.singleSmoke-linux-aarch64
nix build .#checks.x86_64-linux.singleSmoke-linux-armv7-gnueabihf
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
  `packages/fen/src`, and the `packages/providers/<name>/src` trees.
- `--extension-root <dir>` (repeatable), `FEN_EXTENSION_ROOT=<dir>[:<dir>...]` —
  manifest-walking root for flat-layout extensions. Each `<dir>/<kebab>/`
  with a `manifest.fnl` is a discoverable extension; `fen.util.flat_extensions`
  bridges `require :fen.extensions.<snake>...` back to the flat source.

Both flags are stripped from `argv` by the launcher before `fen.main` sees it.
`--extension-root` paths are also folded into `FEN_EXTENSIONS_PATH` so the
loader's user-roots discovery picks them up too.

The `bin/fen-dev` wrapper drives the whole checkout from a single binary:

```sh
nix build .#fenSingle
FEN_BIN=$PWD/result/bin/fen bin/fen-dev

# Equivalent one-liner:
FEN_BIN=$(nix build .#fenSingle --print-out-paths)/bin/fen ./bin/fen-dev
```

It passes `--dev-path` for every workspace `src/` tree plus
`--extension-root packages/extensions`. From there, edit any `.fnl`, run
`/reload` from the TUI, see the change without rebuilding
the binary.

Production users without overlay flags fall through to the embedded archive
unchanged. The `singleDevSmoke`, `singleExtRootSmoke`, and `binFenDevSmoke`
flake checks build the binary and verify module overlays, extension-root
loading, and the `bin/fen-dev` wrapper against fixtures / checkout source.

## Current limitations

This is a phase-1 archive/searcher prototype, not a fully static release.

- The launcher statically links Lua and kubazip, but still dynamically links the
  platform C runtime/libm/libdl.
- Lua C modules are not embedded or statically registered yet:
  - `cjson` for `fen.util.json`
  - `fen_http` for provider HTTP and Codex OAuth refresh (project-owned
    libcurl binding, replaces the former `cURL` rock dep)
  - `termbox2` for the TUI presenter
  - `luasocket` for the web presenter
  - `luaposix` for process helpers
- Provider HTTP/TLS still dynamically links libcurl. Statically linking
  libcurl + its TLS backend for true single-file artifacts is tracked
  separately by #66.
- Interactive TUI use still needs a `termbox2` module strategy.
- ARMv7/aarch64 prototypes are cross-built and smoke-tested with QEMU on
  x86_64 Linux, but release-quality single-file artifacts still need the same
  distribution hardening as the native prototype.
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
