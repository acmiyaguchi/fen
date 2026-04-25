# agent-fennel

A small AI coding-agent CLI written in [Fennel](https://fennel-lang.org/),
compiled to plain Lua. Mirrors the module shape of [pi-mono] (LLM client →
agent loop → TUI) in vastly simplified form. Targets Lua 5.4 on ARMv7
(Raspberry Pi-class hardware) but runs anywhere stock Lua does.

[pi-mono]: https://github.com/badlogic/pi-mono

## Layout

```
src/
  main.fnl              CLI entry: arg parse, dispatch print | interactive
  core/llm.fnl          OpenAI Chat Completions HTTP via lua-curl
  core/agent.fnl        Agent loop: prompt → llm → tool_calls → exec → loop
  core/tools.fnl        Tool registry + built-ins (bash, read, write, ls)
  tui/tui.fnl           ANSI transcript + raw-mode input line (no C deps)
  util/json.fnl         lua-cjson wrapper
  util/log.fnl          Stderr leveled logger
bin/agent-fennel        Shell launcher (sets LUA_PATH, execs lua dist/main.lua)
```

## Quickstart (nix)

```sh
nix develop
make build
OPENAI_API_KEY=sk-... bin/agent-fennel --print "say hi in three words"
OPENAI_API_KEY=sk-... bin/agent-fennel              # interactive TUI
```

## Quickstart (luarocks, no nix)

Requires `lua5.4`, `luarocks`, `make`, plus libcurl headers (`libcurl-dev` /
`curl-devel`) for the `lua-curl` rock to build.

```sh
luarocks install --tree lua_modules --only-deps agent-fennel-1.rockspec
luarocks --tree lua_modules install fennel
PATH="$PWD/lua_modules/bin:$PATH" make build
OPENAI_API_KEY=sk-... bin/agent-fennel --print hi
```

## Make targets

| target | what it does |
| --- | --- |
| `make build` | Compile `src/**/*.fnl` → `dist/**/*.lua` |
| `make run`   | Build then launch the interactive TUI |
| `make test`  | Run `tests/*.fnl` (offline shape checks) |
| `make dist`  | Tarball `dist/`, `bin/`, `README.md` |
| `make clean` | Remove `dist/` |

## Distribution

`make dist` produces `agent-fennel-dist.tar.gz`. Untar it on a target host that
has `lua5.4` and the two runtime rocks (`lua-curl`, `lua-cjson`) installed,
then run `bin/agent-fennel`. The launcher sets `LUA_PATH`/`LUA_CPATH` to find
both the compiled Lua under `dist/` and any rocks installed under a local
`lua_modules/` tree alongside the launcher.

The TUI uses raw ANSI escapes + `stty raw -echo` — no curses dependency, so
deploying to a fresh ARMv7 box only needs the two C rocks above.

## Environment variables

| var | meaning |
| --- | --- |
| `OPENAI_API_KEY`  | Required. |
| `AGENT_FENNEL_LOG` | `debug` \| `info` \| `warn` \| `error` (default `info`). Logs go to stderr; safe to use during the lcurses TUI. |
| `AGENT_FENNEL_LUA` | Override the Lua interpreter the launcher exec's. |

## Built-in tools

`bash`, `read`, `write`, `ls`. Schemas live in `src/core/tools.fnl`. Add new
tools by extending the `registry` table — each entry takes a JSON-Schema-style
`parameters` and an `execute` function returning `{:ok? :output :error}`.

## Status

v0 — non-streaming, OpenAI-only, single transcript window. Intentionally small.
See `/home/anthony/.claude/plans/in-agent-fennel-i-want-wise-iverson.md` for
the design notes and out-of-scope list.
