# fen

A small AI coding-agent CLI written in [Fennel](https://fennel-lang.org/),
compiled to plain Lua. Mirrors [pi-mono]'s canonical interfaces (Message
types, provider abstraction, agent loop) in vastly simplified form. Targets
Lua 5.4 on ARMv7 (Raspberry Pi-class hardware) but runs anywhere stock Lua
does.

[pi-mono]: https://github.com/badlogic/pi-mono

## Layout

```
packages/
  util/src/fen/util/                         JSON, HTTP, path, process helpers
  core/src/fen/core/                         canonical types, agent loop,
                                             sessions, prompt, extensions, LLM registry
  providers/openai/src/fen/providers/        OpenAI Chat Completions provider
  providers/openai-codex/src/fen/providers/  OpenAI Responses + Codex provider/auth
  providers/anthropic/src/fen/providers/     Anthropic Messages provider
  extensions/*/src/fen/extensions/           first-party tools, commands, TUI,
                                             skills, memory, handoff, agent-state
  fen/src/fen/main.fnl                       CLI entrypoint
bin/fen                                      POSIX shell launcher
examples/models.json                         Copy-paste config for Ollama / Ollama Cloud
```

## Quickstart (nix)

```sh
nix develop
make build
OPENAI_API_KEY=sk-... bin/fen --print "say hi in three words"
OPENAI_API_KEY=sk-... bin/fen --provider openai-responses --print hi
ANTHROPIC_API_KEY=sk-ant-... bin/fen --provider anthropic --print hi
ANTHROPIC_API_KEY=sk-ant-... bin/fen --provider anthropic --thinking-budget 2048
# ChatGPT Plus/Pro subscription (run `pi login openai-codex` once first):
bin/fen --provider openai-codex --print hi
OPENAI_API_KEY=sk-... bin/fen              # interactive TUI
OPENAI_API_KEY=sk-... bin/fen --presenter web  # browser UI at http://127.0.0.1:8765/
```

## Quickstart (luarocks, no nix)

Requires `lua5.4`, `luarocks`, `make`, plus libcurl headers (`libcurl-dev` /
`curl-devel`) for the `lua-curl` rock to build.

```sh
make install-local
OPENAI_API_KEY=sk-... bin/fen --print hi
```

`make install-local` installs all checked-in package rockspecs into
`./lua_modules`, then smoke-checks `fen --help`.

## Make targets

| target | what it does |
| --- | --- |
| `make build` | Compile `packages/**/src/**/*.fnl` → package `dist/` trees |
| `make run`   | Build then launch the interactive TUI |
| `make test`  | Run `packages/**/tests/**/*_test.fnl` under busted |
| `make fennel-check` | Strict compile-check source and test `.fnl` files |
| `make install-local` | Install all local rocks into `./lua_modules` |
| `make dist`  | Tarball package `dist/` trees, `bin/`, `README.md` |
| `make clean` | Remove generated build artifacts |

## CLI options

| option | meaning |
| --- | --- |
| `--provider NAME` | `openai`, `openai-responses`, `openai-codex`, `anthropic`, or any name defined in `~/.config/fen/models.json` (default: saved setting, else `openai`) |
| `--model NAME` | Model id. Defaults to saved setting when present; otherwise `gpt-5.5` for openai / openai-responses / openai-codex, `claude-sonnet-4-6` for anthropic, or the first entry under `models` for a custom provider |
| `--system TEXT` | System prompt |
| `--max-tokens N` | Reply token cap (default 16384). Reasoning models (gpt-5*, o1, o3) charge thinking against this cap |
| `--thinking-budget N` | Anthropic only: enable extended thinking with N reasoning tokens |
| `--reasoning-effort E` | OpenAI Responses / Codex: `minimal` \| `low` \| `medium` \| `high` \| `xhigh`. Clamped per-model where the API rejects some values (gpt-5.5 minimal → low, gpt-5.1 xhigh → high). |
| `--print TEXT` | One-shot mode; prints final assistant text and exits |
| `--presenter NAME` | Interactive presenter: `tui` or `web` (default: `tui`). The web presenter serves `http://127.0.0.1:8765/` and requires LuaSocket. |
| `--continue` | Resume the most recent session for the current working directory |
| `--no-session` | Do not write a transcript to disk |
| `--skill PATH` | Additional skill file or directory (repeatable) |
| `--skills DIR` | Backward-compatible alias for `--skill DIR` |
| `--extension PATH` | Load an external extension file or directory (repeatable). Directories expect `init.fnl` or `init.lua`. See [`docs/extensions.md`](docs/extensions.md). |

## Prompt resources

Every system prompt includes the current date and working directory, a short built-in tool list, and tool-aware guidelines. Project context is loaded from `AGENTS.md` or `CLAUDE.md` (first match per directory) in the global agent dir and then from the current directory's ancestors, root-to-leaf. `SYSTEM.md` / `APPEND_SYSTEM.md` overlays are loaded from `~/.config/fen/` and nearest project `.fen/` directories; `--system` takes precedence over `SYSTEM.md`.

Skills are discovered recursively from the original fen roots plus pi/Agent Skills-compatible roots such as `~/.pi/agent/skills`, `~/.agents/skills`, project `.pi/skills`, and ancestor `.agents/skills`. Common Claude/Codex roots are also scanned. Discovery skips dotdirs, `node_modules`, and paths matched by `.gitignore`, `.ignore`, or `.fdignore`. Skill frontmatter requires `description`; `name` falls back to the skill directory. Skills with `disable-model-invocation: true` are not shown to the model.

## Slash commands

Interactive mode supports:

| command | meaning |
| --- | --- |
| `/new` | Reset the current conversation and start a fresh session transcript |
| `/sessions [limit]` | List recent sessions for the current working directory |
| `/resume [latest\|index\|id\|prefix\|path]` | Resume a prior session and append new messages to its transcript |
| `/reload` | Hot-reload core modules after `make build`; preserves current messages |
| `/model [index\|query]` | Show available models or switch by index/name. Successful switches are saved as the default provider/model. |
| `/status` | Show model, provider, message count, approximate context tokens, provider-reported token usage, and active session |
| `/expand [on/off]` | Toggle collapsed vs full tool-result bodies |
| `/markdown [on/off]` | Toggle block-level Markdown rendering of assistant text |
| `/help` | Show available slash commands |

## Environment variables

| var | meaning |
| --- | --- |
| `OPENAI_API_KEY` | Required when `--provider=openai` or `--provider=openai-responses` |
| `ANTHROPIC_API_KEY` | Required when `--provider=anthropic` |
| `PI_CODING_AGENT_DIR` | Override the auth.json directory used by `--provider=openai-codex` (default `~/.pi/agent/`). Same env var pi-mono honors. |
| `FEN_LOG` | `debug` \| `info` \| `warn` \| `error` (default `info`). Logs go to stderr; safe during the TUI. |
| `FEN_LUA` | Override the Lua interpreter the launcher exec's |
| `FEN_EXTENSIONS_PATH` | Colon-separated extension discovery roots. See [`docs/extensions.md`](docs/extensions.md). |

## Distribution

`nix build` produces a runnable Nix package at `result/bin/fen`, and
`nix run .# -- --help` runs it directly. This is the reproducible package
baseline used for release work.

`nix build .#dist` produces a same-architecture Linux bundle tarball such as
`result/fen-<version>-linux-x86_64.tar.gz`. It includes Lua 5.4, fen's compiled
Lua modules, first-party Lua C modules, and shared libraries discovered by
`ldd` at build time. Extract it on a Linux host with the same architecture/ABI
and run `bin/fen` from the extracted directory. This bundle is intended to be
portable across Linux distributions without installing Lua rocks manually.

`make dist` produces the older lightweight `fen-dist.tar.gz`. Untar it on a
target host that has `lua5.4` and runtime rocks (`lua-curl`, `lua-cjson`, and
optional `luasocket` for `--presenter web`) installed, then run `bin/fen`. The
launcher sets `LUA_PATH`/`LUA_CPATH` to find compiled Lua under package `dist/`
trees and any rocks installed under a local `lua_modules/` tree alongside the
launcher.

The optional web presenter (`--presenter web`) uses LuaSocket to serve a tiny
local HTML page plus Server-Sent Events. `nix develop` includes LuaSocket, and
`make install-local` installs it through `packages/extensions/web/fen-ext-web-1-1.rockspec`.
Standard TUI usage does not require LuaSocket; if the web presenter is selected
without it, fen exits with `web presenter requires luasocket`.

The TUI is built on [termbox2](https://github.com/termbox/termbox2), a small
single-header terminal library. There's no published `lua-termbox2` rock, so
the binding is vendored in-tree at
`packages/extensions/tui/vendor/lua_termbox2.c` +
`packages/extensions/tui/vendor/termbox2.h` and compiled to
`packages/extensions/tui/dist/termbox2.so` by `make build`. The launcher adds
that package dist directory to `LUA_CPATH` so the binding loads alongside the
Fennel-compiled Lua. Cross-arch deployment (e.g. building on x86 for ARMv7) means rebuilding
the `.so` on the target — same constraint as `lua-curl` and `lua-cjson`.

## Extensions

Extensions can add slash commands, tools, hooks, system-prompt fragments, event
subscribers, presenters, status-bar items, and panels. External extensions are loaded from
`$FEN_EXTENSIONS_PATH`, XDG config roots, or explicit `--extension <path>`.
See [`docs/extensions.md`](docs/extensions.md) for the manifest format,
registration API, reload behavior, and examples.

## Built-in tools

`bash`, `read`, `write`, `ls`, `edit`, `grep`, `find`. They are registered by
the first-party `builtin_tools` extension
(`packages/extensions/builtin-tools/src/fen/extensions/builtin_tools/`) using the
same extension API external tools use. Shared execution helpers stay in
`packages/core/src/fen/core/tools.fnl`.
`edit` takes
`{path, edits: [{old_string, new_string}]}` with multi-edit support, exact
match, and overlap detection. `grep` and `find` shell out to POSIX
`grep`/`find` (no `rg`/`fd` dependency). Add new built-in tools by adding the
tool implementation under
`packages/extensions/builtin-tools/src/fen/extensions/builtin_tools/` and registering it
from that extension.

## Settings

fen reads small user preferences from `~/.config/fen/settings.json` (or
`$XDG_CONFIG_HOME/fen/settings.json`). CLI flags always take precedence. The
`/model` command writes the default provider/model after a successful switch,
so selecting Codex once with `/model openai-codex/gpt-5.5` makes future
launches default to Codex.

```json
{
  "defaultProvider": "openai-codex",
  "defaultModel": "gpt-5.5"
}
```

If the saved provider is unavailable, missing auth, or no longer configured,
fen warns and falls back to the built-in `openai` default. `models.json` remains
the provider/model registry; `settings.json` is mutable preference state.

## Custom providers (Ollama, vLLM, LM Studio, proxies)

Any OpenAI-compatible HTTP endpoint can be wired up via
`~/.config/fen/models.json` — no code changes, no rebuild. Copy
[`examples/models.json`](examples/models.json) into place and edit:

```sh
mkdir -p ~/.config/fen
cp examples/models.json ~/.config/fen/models.json
$EDITOR ~/.config/fen/models.json
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
fen --provider ollama-cloud --print "say hi"
```

Edits to `models.json` are picked up via `/reload` in interactive mode
(no process restart). The file is per-user state — fen does not
ship one and `make dist` doesn't bundle it.

| field | meaning |
| --- | --- |
| `baseUrl` | API base — fen appends `/chat/completions` if needed. Both `https://ollama.com/v1` and `https://ollama.com/v1/chat/completions` work. |
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

1. Add a provider module under the appropriate
   `packages/providers/<pkg>/src/fen/providers/` tree exporting at minimum
   `{:api :provider :complete :convert-messages :convert-tools
     :map-stop-reason :parse-response}`.
2. `(register …)` it in `packages/core/src/fen/core/llm/init.fnl` or register it
   from `packages/fen/src/fen/main.fnl` for first-party providers.
3. Add a `--provider` mapping in `packages/fen/src/fen/main.fnl` when it should
   be CLI-selectable.
4. Add a wire-conversion test under the provider package's `tests/` directory.

The agent loop and tool registry don't change — they speak only canonical
types.

## ChatGPT Plus/Pro Codex subscription

`--provider openai-codex` lets you run fen against your ChatGPT
subscription instead of `OPENAI_API_KEY`-billed `/v1/responses`. fen
does not implement the OAuth login flow itself — pi-mono already does it well,
and that auth UX is a poor fit for a small-device CLI. Instead, we read the
credentials pi-mono persists in `~/.pi/agent/auth.json` and refresh tokens
ourselves when they're expiring.

Setup:

```sh
# 1. On any host with pi-mono installed, run the OAuth flow once.
pi login openai-codex

# 2. fen then sees the credentials automatically.
bin/fen --provider openai-codex --print "what is 2+2?"
```

Token refresh is lazy: when a request would otherwise go out with a token
expiring in the next 60 seconds, we POST to `auth.openai.com/oauth/token`,
extract the new `chatgpt_account_id` from the access JWT, and write the new
record back to `auth.json` atomically. No login UX in fen itself.

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
