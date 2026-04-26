# agent-fennel

A small AI coding-agent CLI written in [Fennel](https://fennel-lang.org/),
compiled to plain Lua. Mirrors [pi-mono]'s canonical interfaces (Message
types, provider abstraction, agent loop) in vastly simplified form. Targets
Lua 5.4 on ARMv7 (Raspberry Pi-class hardware) but runs anywhere stock Lua
does.

[pi-mono]: https://github.com/badlogic/pi-mono

## Layout

```
src/
  main.fnl                          CLI entry: --provider dispatch
  core/types.fnl                    Canonical Message / Tool / StopReason
  core/llm.fnl                      Provider registry / dispatcher
  core/agent.fnl                    Agent loop on canonical messages
  core/tools.fnl                    AgentTool list + built-ins
  providers/openai_completions.fnl  OpenAI Chat Completions provider
  providers/anthropic_messages.fnl  Anthropic Messages provider
  tui/tui.fnl                       Full-screen TUI on termbox2 (status line,
                                    scrollable transcript, sticky input box)
  util/json.fnl                     lua-cjson wrapper
  util/log.fnl                      Stderr leveled logger
bin/agent-fennel                    Shell launcher
```

## Quickstart (nix)

```sh
nix develop
make build
OPENAI_API_KEY=sk-... bin/agent-fennel --print "say hi in three words"
ANTHROPIC_API_KEY=sk-ant-... bin/agent-fennel --provider anthropic --print hi
ANTHROPIC_API_KEY=sk-ant-... bin/agent-fennel --provider anthropic --thinking-budget 2048
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
| `make test`  | Run `tests/*_test.fnl` under busted |
| `make dist`  | Tarball `dist/`, `bin/`, `README.md` |
| `make clean` | Remove `dist/` |

## CLI options

| option | meaning |
| --- | --- |
| `--provider NAME` | `openai` or `anthropic` (default: `openai`) |
| `--model NAME` | Model id. Defaults: `gpt-5.5` for openai, `claude-sonnet-4-6` for anthropic |
| `--system TEXT` | System prompt |
| `--max-tokens N` | Reply token cap (default 16384). Reasoning models (gpt-5*, o1, o3) charge thinking against this cap |
| `--thinking-budget N` | Anthropic only: enable extended thinking with N reasoning tokens |
| `--print TEXT` | One-shot mode; prints final assistant text and exits |
| `--continue` | Resume the most recent session for the current working directory |
| `--no-session` | Do not write a transcript to disk |

## Slash commands

Interactive mode supports:

| command | meaning |
| --- | --- |
| `/new` | Reset the current conversation and start a fresh session transcript |
| `/reload` | Hot-reload core modules after `make build`; preserves current messages |
| `/status` | Show model, provider, message count, approximate context tokens, and provider-reported token usage |
| `/help` | Show available slash commands |

## Environment variables

| var | meaning |
| --- | --- |
| `OPENAI_API_KEY` | Required when `--provider=openai` |
| `ANTHROPIC_API_KEY` | Required when `--provider=anthropic` |
| `AGENT_FENNEL_LOG` | `debug` \| `info` \| `warn` \| `error` (default `info`). Logs go to stderr; safe during the TUI. |
| `AGENT_FENNEL_LUA` | Override the Lua interpreter the launcher exec's |

## Distribution

`make dist` produces `agent-fennel-dist.tar.gz`. Untar it on a target host that
has `lua5.4` and the two runtime rocks (`lua-curl`, `lua-cjson`) installed,
then run `bin/agent-fennel`. The launcher sets `LUA_PATH`/`LUA_CPATH` to find
both the compiled Lua under `dist/` and any rocks installed under a local
`lua_modules/` tree alongside the launcher.

The TUI is built on [termbox2](https://github.com/termbox/termbox2), a small
single-header terminal library. There's no published `lua-termbox2` rock, so
the binding is vendored in-tree at `vendor/lua_termbox2.c` + `vendor/termbox2.h`
and compiled to `dist/termbox2.so` by `make build`. The launcher adds
`dist/?.so` to `LUA_CPATH` so the binding loads alongside the Fennel-compiled
Lua. Cross-arch deployment (e.g. building on x86 for ARMv7) means rebuilding
the `.so` on the target — same constraint as `lua-curl` and `lua-cjson`.

## Built-in tools

`bash`, `read`, `write`, `ls`, `edit`, `grep`, `find`. Schemas live in
`src/core/tools.fnl`. `edit` takes `{path, edits: [{old_string, new_string}]}`
with multi-edit support, exact match, and overlap detection. `grep` and
`find` shell out to POSIX `grep`/`find` (no `rg`/`fd` dependency). Add new
tools by appending to the `registry` array — each entry needs `name`,
`label`, `description`, `parameters` (JSON-Schema), and `execute` returning
`{:content [text-blocks] :is-error? bool}`.

## Adding a third provider

1. Write `src/providers/<name>.fnl` exporting at minimum
   `{:api :provider :complete :convert-messages :convert-tools
     :map-stop-reason :parse-response}`.
2. `(register …)` it in `src/core/llm.fnl`.
3. Add a `--provider` mapping in `src/main.fnl`.
4. Add a wire-conversion test under `tests/provider_<name>_test.fnl`.

The agent loop and tool registry don't change — they speak only canonical
types.

## Status

Two providers (OpenAI Chat Completions, Anthropic Messages), non-streaming,
single transcript window. Canonical types and provider seam mirror pi-mono's
shapes; future work (streaming, OAuth, sessions, etc.) extends additively.
See `/home/anthony/.claude/plans/in-agent-fennel-i-want-wise-iverson.md` for
the original design boundary.
