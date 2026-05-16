# Scripts

`fen run` runs Lua and Fennel scripts with fen's embedded Lua 5.4 runtime.
It is meant for small portable scripts on systems where `lua`, `fennel`, or system LuaRocks are not installed.
It is separate from the coding-agent flow and does not initialize providers, sessions, or the TUI.

## Usage

```sh
fen run [--lua|--fennel] SCRIPT [ARG...]
```

Fen infers the language from the script path.
Files ending in `.fnl` run as Fennel.
All other paths run as Lua unless `--fennel` is passed.
Use `--lua` or `--fennel` when the extension is ambiguous.
Use `--` before a script path that starts with `-`.

Examples:

```sh
fen run hello.lua one two
fen run hello.fnl one two
fen run --fennel ./script-without-extension one two
fen run -- --script-name-that-starts-with-dash
```

A shebang can use `env -S` on systems that support it:

```fennel
#!/usr/bin/env -S fen run --fennel
(print "hello from Fennel")
```

## Script arguments

`fen run` follows Lua's script argument convention.
Inside the script, `arg[0]` is the script path.
`arg[1]` through `arg[n]` are the arguments after the script path.
The same script arguments are also passed as varargs, so a script can read them through `...`.
Arguments before the script path, such as `fen`, `run`, and language flags, are available at negative `arg` indexes for compatibility.

For example:

```lua
print(arg[0], arg[1], arg[2])
local first, second = ...
print(first, second)
```

## Fennel modules

When running a `.fnl` script or using `--fennel`, fen installs Fennel's module searcher for the process.
This lets Fennel scripts require sibling modules from the current working directory, such as `require "helper"` loading `helper.fnl`.
The runner exits after the script completes, so this searcher mutation does not leak into agent mode.

## Dependencies and `fen ext build`

On startup, fen prepends the fen-managed rocks tree to `package.path` and `package.cpath` when the tree exists.
The default tree is:

```sh
${XDG_DATA_HOME:-~/.local/share}/fen/rocks
```

Set `FEN_ROCKS_TREE` to use another tree.
This is the same tree used by extension dependency loading and by `fen ext build`.

A portable pure-Lua dependency workflow looks like this:

```sh
fen ext build ./vendor/my-lib
fen run script.fnl
```

The bundled LuaRocks runtime is local-only.
It is intended for local rockspec builds, especially pure-Lua dependencies.
It does not include the luarocks.org network/download workflow.
Native rocks still require a system C toolchain, Lua development headers, and a compatible ABI.
Fully static or musl release artifacts may not be able to load native `.so` rocks at runtime.

## Supported module surface

The supported script surface is intentionally small:

- Lua 5.4 standard libraries;
- bundled Fennel for Fennel scripts;
- modules found through the normal `package.path` and `package.cpath`;
- modules installed in the fen-managed rocks tree.

Some fen internals and bundled helper modules may be require-able as an implementation detail.
Do not treat `fen.*`, `luarocks.*`, `fen_http`, `fen_process`, or other internal modules as a stable script API unless they are documented separately.

## Exit codes

| exit code | meaning |
| --- | --- |
| `0` | the script loaded and returned normally |
| `1` | the script failed to load, compile, or run |
| `2` | `fen run` was used incorrectly |

If a script calls `os.exit(n)`, Lua exits the process with that status.
