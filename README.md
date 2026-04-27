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
  core/models.fnl                   ~/.config/agent-fennel/models.json loader
                                    (custom OpenAI-compat providers — Ollama,
                                    vLLM, LM Studio, etc.)
  providers/openai_completions.fnl  OpenAI Chat Completions provider
  providers/anthropic_messages.fnl  Anthropic Messages provider
  tui/tui.fnl                       Full-screen TUI on termbox2 (status line,
                                    scrollable transcript, sticky input box)
  util/json.fnl                     lua-cjson wrapper
  util/log.fnl                      Stderr leveled logger
bin/agent-fennel                    Shell launcher
examples/models.json                Copy-paste config for Ollama / Ollama Cloud
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
| `--provider NAME` | `openai`, `anthropic`, or any name defined in `~/.config/agent-fennel/models.json` (default: `openai`) |
| `--model NAME` | Model id. Defaults: `gpt-5.5` for openai, `claude-sonnet-4-6` for anthropic, or the first entry under `models` for a custom provider |
| `--system TEXT` | System prompt |
| `--max-tokens N` | Reply token cap (default 16384). Reasoning models (gpt-5*, o1, o3) charge thinking against this cap |
| `--thinking-budget N` | Anthropic only: enable extended thinking with N reasoning tokens |
| `--print TEXT` | One-shot mode; prints final assistant text and exits |
| `--continue` | Resume the most recent session for the current working directory |
| `--no-session` | Do not write a transcript to disk |
| `--skills DIR` | Additional directory to scan for `SKILL.md` files (repeatable) |

## Slash commands

Interactive mode supports:

| command | meaning |
| --- | --- |
| `/new` | Reset the current conversation and start a fresh session transcript |
| `/reload` | Hot-reload core modules after `make build`; preserves current messages |
| `/status` | Show model, provider, message count, approximate context tokens, and provider-reported token usage |
| `/expand [on/off]` | Toggle collapsed vs full tool-result bodies |
| `/markdown [on/off]` | Toggle block-level Markdown rendering of assistant text |
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

## Custom providers (Ollama, vLLM, LM Studio, proxies)

Any OpenAI-compatible HTTP endpoint can be wired up via
`~/.config/agent-fennel/models.json` — no code changes, no rebuild. Copy
[`examples/models.json`](examples/models.json) into place and edit:

```sh
mkdir -p ~/.config/agent-fennel
cp examples/models.json ~/.config/agent-fennel/models.json
$EDITOR ~/.config/agent-fennel/models.json
```

Minimal Ollama Cloud example:

```json
{"providers": {"ollama-cloud": {
  "baseUrl": "https://ollama.com/v1",
  "api": "openai-completions",
  "apiKey": "OLLAMA_API_KEY",
  "compat": {"maxTokensField": "max_tokens"},
  "models": [{"id": "gpt-oss:120b"}]
}}}
```

```sh
export OLLAMA_API_KEY=...    # https://ollama.com/settings/keys
agent-fennel --provider ollama-cloud --print "say hi"
```

Edits to `models.json` are picked up via `/reload` in interactive mode
(no process restart). The file is per-user state — agent-fennel does not
ship one and `make dist` doesn't bundle it.

| field | meaning |
| --- | --- |
| `baseUrl` | API base — agent-fennel appends `/chat/completions` if needed. Both `https://ollama.com/v1` and `https://ollama.com/v1/chat/completions` work. |
| `api` | `openai-completions` or `anthropic-messages`. |
| `apiKey` | Either an env-var name (UPPER\_SNAKE\_CASE → `os.getenv`) or a literal. Ollama-style local servers can use any literal — auth is sent only when non-empty. |
| `compat` | OpenAI-compat overrides. Today only `maxTokensField` (`"max_tokens"` for Ollama) is honored; other keys are accepted for forward compat. |
| `models` | Array of `{id, ...}`. The first entry's `id` is the default when `--model` isn't passed. |

**Deliberately not implemented** (vs pi-mono's `models.json`): `!shell-cmd`
apiKey resolution, `modelOverrides`, per-model `compat`, cost/pricing
fields, multi-input (image) declarations.

## Adding a built-in provider

For a provider that doesn't fit OpenAI Chat Completions or Anthropic Messages
(e.g. OpenAI Responses, Gemini), add a real provider module:

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
shapes; future work such as streaming, OAuth, context compaction, and richer
rendering extends additively. See
`/home/anthony/.claude/plans/in-agent-fennel-i-want-wise-iverson.md` for the
original design boundary.
