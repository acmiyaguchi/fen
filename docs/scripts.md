# Scripts

`fen run` runs Lua and Fennel scripts with fen's embedded Lua 5.4 runtime.
`fen eval` evaluates inline Lua or Fennel code with the same runtime.
They are meant for small portable scripts on systems where `lua`, `fennel`, or system LuaRocks are not installed.
They are separate from the coding-agent flow and do not initialize providers, sessions, or the TUI.

## Usage

```sh
fen run [--lua|--fennel] SCRIPT [ARG...]
fen eval [--lua|--fennel] CODE [ARG...]
```

Fen infers the language for `fen run` from the script path.
Files ending in `.fnl` run as Fennel.
All other paths run as Lua unless `--fennel` is passed.
Use `--lua` or `--fennel` when the extension is ambiguous.
`fen eval` defaults to Lua because there is no file extension to inspect.
Pass `--fennel` to evaluate Fennel code.
Use `--` before a script path or code string that starts with `-`.

Examples:

```sh
fen run hello.lua one two
fen run hello.fnl one two
fen run --fennel ./script-without-extension one two
fen run -- --script-name-that-starts-with-dash
fen eval 'print("hello from lua", ...)'
fen eval --fennel '(print "hello from Fennel" ...)'
fen eval -- '--code-that-starts-with-dash'
```

A shebang can use `env -S` on systems that support it:

```fennel
#!/usr/bin/env -S fen run --fennel
(print "hello from Fennel")
```

## Script and eval arguments

`fen run` follows Lua's script argument convention.
Inside a script, `arg[0]` is the script path.
`arg[1]` through `arg[n]` are the arguments after the script path.
The same script arguments are also passed as varargs, so a script can read them through `...`.
Arguments before the script path, such as `fen`, `run`, and language flags, are available at negative `arg` indexes for compatibility.

`fen eval` uses the same positive arguments and varargs convention for arguments after the code string.
Inside eval code, `arg[0]` is the synthetic chunk name `=(fen eval)`.
Arguments before the code string, such as `fen`, `eval`, and language flags, are available at negative `arg` indexes.

For example:

```lua
print(arg[0], arg[1], arg[2])
local first, second = ...
print(first, second)
```

## Fennel modules

When running a `.fnl` script, using `fen run --fennel`, or using `fen eval --fennel`, fen installs Fennel's module searcher for the process.
This lets Fennel scripts and eval snippets require sibling modules from the current working directory, such as `require "helper"` loading `helper.fnl`.
The runner exits after the script or eval completes, so this searcher mutation does not leak into agent mode.

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
fen eval --fennel '(print ((require :my-lib).value))'
```

The bundled LuaRocks runtime is local-only.
It is intended for local rockspec builds, especially pure-Lua dependencies.
It does not include the luarocks.org network/download workflow.
Native rocks still require a system C toolchain, Lua development headers, and a compatible ABI.
Fully static or musl release artifacts may not be able to load native `.so` rocks at runtime.

## Safety

`fen run` and `fen eval` are not sandboxes.
They execute arbitrary local code with the same permissions as the `fen` process.
Use them only with code you trust.

## Supported module surface

The supported script/eval surface is intentionally small:

- Lua 5.4 standard libraries;
- bundled Fennel for Fennel scripts and eval snippets;
- modules found through the normal `package.path` and `package.cpath`;
- modules installed in the fen-managed rocks tree.

Some fen internals and bundled helper modules may be require-able as an implementation detail.
Do not treat `fen.*`, `luarocks.*`, `fen_http`, `fen_process`, or other internal modules as a stable script API unless they are documented separately.

## Exit codes

| exit code | meaning |
| --- | --- |
| `0` | the script/code loaded and returned normally |
| `1` | the script/code failed to load, compile, or run |
| `2` | `fen run` or `fen eval` was used incorrectly |

If a script calls `os.exit(n)`, Lua exits the process with that status.
