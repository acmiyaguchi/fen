# Single-file executable prototype

`nix build .#fenSingle` builds a Linux prototype at `result/bin/fen`.

The prototype is a native launcher statically linked to Lua 5.4 and kubazip.
The build creates a deterministic ZIP from the packaged `share/lua/5.4` module tree,
appends that ZIP to the launcher ELF, and installs a `package.searchers` entry
that loads Lua modules from the embedded archive.

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

## Current limitations

This is a phase-1 archive/searcher prototype, not a fully static release.

- The launcher statically links Lua and kubazip, but still dynamically links the
  platform C runtime/libm/libdl.
- Lua C modules are not embedded or statically registered yet:
  - `cjson` for `fen.util.json`
  - `cURL` for provider HTTP and Codex OAuth refresh
  - `termbox2` for the TUI presenter
  - `luasocket` for the web presenter
  - `luaposix` for process helpers
- Provider HTTP/TLS remains tied to lua-curl/libcurl. Reducing that complexity
  is tracked separately by #65.
- Interactive TUI use still needs a `termbox2` module strategy.
- ARMv7/aarch64 prototypes are cross-built and smoke-tested with QEMU on
  x86_64 Linux, but release-quality single-file artifacts still need the same
  distribution hardening as the native prototype.
- Embedded modules do not have ordinary filesystem paths. Current `/reload`
  fingerprinting uses `package.searchpath`, so embedded modules are treated as
  distribution-time fixed. Hot-reload development should continue to use the
  normal source/dist tree.

## Inspecting the archive

Standard ZIP tools can inspect the appended archive, with a warning about the
ELF prefix:

```sh
unzip -l result/bin/fen | head
```
