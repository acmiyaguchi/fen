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
  core/tools.fnl                    AgentTool executor/helpers
  extensions/builtin_tools/         Built-in tool extension
  extensions/builtin_commands/      Built-in slash command extension
  core/models.fnl                   ~/.config/agent-fennel/models.json loader
                                    (custom OpenAI-compat providers — Ollama,
                                    vLLM, LM Studio, etc.)
  providers/openai_completions.fnl  OpenAI Chat Completions provider
  providers/openai_responses.fnl    OpenAI Responses API provider
  providers/openai_responses_shared.fnl  Shared Responses event reducer
  providers/openai_codex_responses.fnl   ChatGPT Plus/Pro Codex provider
  providers/anthropic_messages.fnl  Anthropic Messages provider
  auth/storage.fnl                  ~/.pi/agent/auth.json reader/writer
  auth/openai_codex.fnl             Codex OAuth refresh + JWT decode
  util/base64.fnl                   base64url decoder (JWT payloads)
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
OPENAI_API_KEY=sk-... bin/agent-fennel --provider openai-responses --print hi
ANTHROPIC_API_KEY=sk-ant-... bin/agent-fennel --provider anthropic --print hi
ANTHROPIC_API_KEY=sk-ant-... bin/agent-fennel --provider anthropic --thinking-budget 2048
# ChatGPT Plus/Pro subscription (run `pi login openai-codex` once first):
bin/agent-fennel --provider openai-codex --print hi
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
| `--provider NAME` | `openai`, `openai-responses`, `openai-codex`, `anthropic`, or any name defined in `~/.config/agent-fennel/models.json` (default: `openai`) |
| `--model NAME` | Model id. Defaults: `gpt-5.5` for openai / openai-responses / openai-codex, `claude-sonnet-4-6` for anthropic, or the first entry under `models` for a custom provider |
| `--system TEXT` | System prompt |
| `--max-tokens N` | Reply token cap (default 16384). Reasoning models (gpt-5*, o1, o3) charge thinking against this cap |
| `--thinking-budget N` | Anthropic only: enable extended thinking with N reasoning tokens |
| `--reasoning-effort E` | OpenAI Responses / Codex: `minimal` \| `low` \| `medium` \| `high` \| `xhigh`. Clamped per-model where the API rejects some values (gpt-5.5 minimal → low, gpt-5.1 xhigh → high). |
| `--print TEXT` | One-shot mode; prints final assistant text and exits |
| `--continue` | Resume the most recent session for the current working directory |
| `--no-session` | Do not write a transcript to disk |
| `--skill PATH` | Additional skill file or directory (repeatable) |
| `--skills DIR` | Backward-compatible alias for `--skill DIR` |
| `--extension PATH` | Load an external extension file or directory (repeatable). Directories expect `init.fnl` or `init.lua`. See [`docs/extensions.md`](docs/extensions.md). |

## Prompt resources

Every system prompt includes the current date and working directory, a short built-in tool list, and tool-aware guidelines. Project context is loaded from `AGENTS.md` or `CLAUDE.md` (first match per directory) in the global agent dir and then from the current directory's ancestors, root-to-leaf. `SYSTEM.md` / `APPEND_SYSTEM.md` overlays are loaded from `~/.config/agent-fennel/` and nearest project `.agent-fennel/` directories; `--system` takes precedence over `SYSTEM.md`.

Skills are discovered recursively from the original agent-fennel roots plus pi/Agent Skills-compatible roots such as `~/.pi/agent/skills`, `~/.agents/skills`, project `.pi/skills`, and ancestor `.agents/skills`. Common Claude/Codex roots are also scanned. Discovery skips dotdirs, `node_modules`, and paths matched by `.gitignore`, `.ignore`, or `.fdignore`. Skill frontmatter requires `description`; `name` falls back to the skill directory. Skills with `disable-model-invocation: true` are not shown to the model.

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
| `OPENAI_API_KEY` | Required when `--provider=openai` or `--provider=openai-responses` |
| `ANTHROPIC_API_KEY` | Required when `--provider=anthropic` |
| `PI_CODING_AGENT_DIR` | Override the auth.json directory used by `--provider=openai-codex` (default `~/.pi/agent/`). Same env var pi-mono honors. |
| `AGENT_FENNEL_LOG` | `debug` \| `info` \| `warn` \| `error` (default `info`). Logs go to stderr; safe during the TUI. |
| `AGENT_FENNEL_LUA` | Override the Lua interpreter the launcher exec's |
| `FEN_EXTENSIONS_PATH` | Colon-separated extension discovery roots. See [`docs/extensions.md`](docs/extensions.md). |

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

## Extensions

Extensions can add slash commands, tools, hooks, system-prompt fragments, event
subscribers, and presenters. External extensions are loaded from
`$FEN_EXTENSIONS_PATH`, XDG config roots, or explicit `--extension <path>`.
See [`docs/extensions.md`](docs/extensions.md) for the manifest format,
registration API, reload behavior, and examples.

## Built-in tools

`bash`, `read`, `write`, `ls`, `edit`, `grep`, `find`. They are registered by
the first-party `builtin_tools` extension (`src/extensions/builtin_tools/`) using the
same extension API external tools use. The tool implementations live under
`src/extensions/builtin_tools/`; shared execution helpers stay in `src/core/tools.fnl`.
`edit` takes
`{path, edits: [{old_string, new_string}]}` with multi-edit support, exact
match, and overlap detection. `grep` and `find` shell out to POSIX
`grep`/`find` (no `rg`/`fd` dependency). Add new built-in tools by adding the
tool implementation under `src/extensions/builtin_tools/` and registering it
from that extension.

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

## ChatGPT Plus/Pro Codex subscription

`--provider openai-codex` lets you run agent-fennel against your ChatGPT
subscription instead of `OPENAI_API_KEY`-billed `/v1/responses`. agent-fennel
does not implement the OAuth login flow itself — pi-mono already does it well,
and that auth UX is a poor fit for a small-device CLI. Instead, we read the
credentials pi-mono persists in `~/.pi/agent/auth.json` and refresh tokens
ourselves when they're expiring.

Setup:

```sh
# 1. On any host with pi-mono installed, run the OAuth flow once.
pi login openai-codex

# 2. agent-fennel then sees the credentials automatically.
bin/agent-fennel --provider openai-codex --print "what is 2+2?"
```

Token refresh is lazy: when a request would otherwise go out with a token
expiring in the next 60 seconds, we POST to `auth.openai.com/oauth/token`,
extract the new `chatgpt_account_id` from the access JWT, and write the new
record back to `auth.json` atomically. No login UX in agent-fennel itself.

Honors `PI_CODING_AGENT_DIR` for relocated auth dirs (same env var pi-mono
respects). `/status` shows `auth: subscription (via pi)` so you can tell at
a glance which path the live agent is on.

## Status

Three OpenAI-shape providers (Chat Completions, Responses, Codex subscription),
Anthropic Messages, native streaming with delta event coalescing in the TUI,
cooperative HTTP, full-screen termbox2 TUI, session persistence, custom
OpenAI-compatible providers, skills/project-context loading, and lightweight
Markdown rendering. Canonical types and provider seams mirror pi-mono's shapes;
open roadmap items such as a native PKCE login flow, richer session/model UX,
and tool batching are tracked in GitHub issues and extend additively. See
`/home/anthony/.claude/plans/in-agent-fennel-i-want-wise-iverson.md` for the
original design boundary.
