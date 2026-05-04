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
  extensions/*/{manifest,init}.fnl           first-party tools, commands, TUI,
                                             skills, memory, handoff, agent-state
  fen/src/fen/main.fnl                       CLI entrypoint
bin/fen-dev                                  Source-checkout dev wrapper for the single-file runtime
examples/models.json                         Copy-paste config for Ollama / Ollama Cloud
```

## Quickstart (Nix, canonical dev workflow)

Build the single-file runtime once, then drive the source checkout through
`bin/fen-dev`. The wrapper passes `--dev-path` for package source trees and
`--extension-root` for flat first-party extensions, so `.fnl` edits are compiled
on demand and picked up by `/reload` without rebuilding.

```sh
nix build .#fen
FEN_BIN=$PWD/result/bin/fen bin/fen-dev
```

One-shot examples use the same wrapper while developing:

```sh
OPENAI_API_KEY=sk-... FEN_BIN=$PWD/result/bin/fen bin/fen-dev --print "say hi in three words"
OPENAI_API_KEY=sk-... FEN_BIN=$PWD/result/bin/fen bin/fen-dev --provider openai-responses --print hi
ANTHROPIC_API_KEY=sk-ant-... FEN_BIN=$PWD/result/bin/fen bin/fen-dev --provider anthropic --print hi
ANTHROPIC_API_KEY=sk-ant-... FEN_BIN=$PWD/result/bin/fen bin/fen-dev --provider anthropic --thinking-budget 2048
# ChatGPT Plus/Pro subscription (run `fen --login openai-codex` once first):
FEN_BIN=$PWD/result/bin/fen bin/fen-dev --provider openai-codex --print hi
OPENAI_API_KEY=sk-... FEN_BIN=$PWD/result/bin/fen bin/fen-dev              # interactive TUI
OPENAI_API_KEY=sk-... FEN_BIN=$PWD/result/bin/fen bin/fen-dev --presenter web  # browser UI
```

Fast local checks are still useful while editing:

```sh
nix develop
fennel scripts/fennel-check.fnl
make test
```

`nix flake check` is the canonical reproducible CI/check surface.

## Workflow commands

| command | status | purpose |
| --- | --- | --- |
| `nix build .#fen` | canonical dev runtime / distribution | Build the single-file binary used by `bin/fen-dev`. |
| `FEN_BIN=... bin/fen-dev` | canonical dev | Run directly from `.fnl` source overlays; `/reload` sees edits without generated build output. |
| `nix flake check` | canonical CI | Reproducible checks. |
| `fennel scripts/fennel-check.fnl` | fast local check | Strict compile/global check for `.fnl` source and tests. |
| `make dev` | convenience | Build `.#fen`, then run `bin/fen-dev`. |
| `make test` | convenience | Run the fast local Busted suite. |
| `make clean` | convenience | Remove generated local artifacts and Nix result symlinks. |
| `fen ext build DIR` | extension deps | Build a drop-in extension's single rockspec into the fen-managed rocks tree using the bundled local-only LuaRocks runtime. |

### Extension dependencies and LuaRocks

For a dependency-bearing drop-in extension, put exactly one `*.rockspec` next to
`manifest.fnl` / `init.fnl`, then run:

```sh
fen ext build .fen/extensions/myext
```

The default install tree is `${XDG_DATA_HOME:-~/.local/share}/fen/rocks`; set
`FEN_ROCKS_TREE` to override it. Fen prepends that tree to `package.path` and
`package.cpath` on startup when it exists. If an extension fails to load because
a Lua module is missing, fen reports either `fen ext build <dir>` when a
rockspec is present or a manual `luarocks install --tree ...` command when it is
not.

A direct LuaRocks install is no longer a primary user workflow. Rockspecs remain
for publishing and maintainer smoke tests. The single-file binary bundles a
local-only LuaRocks runtime plus `lfs`/`dkjson` for this command; it does not
support the network/download path.

## CLI options

| option | meaning |
| --- | --- |
| `--provider NAME` | `openai`, `openai-responses`, `openai-codex`, `anthropic`, or any name defined in `~/.config/fen/models.json` (default: saved setting, else `openai`) |
| `--model NAME` | Model id. Defaults to saved setting when present; otherwise `gpt-5.4-nano` for openai / openai-responses, `gpt-5.5` for openai-codex, `claude-sonnet-4-6` for anthropic, or the first entry under `models` for a custom provider |
| `--system TEXT` | System prompt |
| `--max-tokens N` | Reply token cap (default 16384). Reasoning models (gpt-5*, o1, o3) charge thinking against this cap |
| `--retries N` | Provider HTTP attempts for transient failures such as 429, 5xx, timeout, reset, or refused connection (default 4; use 1 to disable) |
| `--thinking-budget N` | Anthropic only: enable extended thinking with N reasoning tokens |
| `--reasoning-effort E` | OpenAI Responses / Codex: `minimal` \| `low` \| `medium` \| `high` \| `xhigh`. Clamped per-model where the API rejects some values (gpt-5.5 minimal → low, gpt-5.1 xhigh → high). |
| `--print TEXT` | One-shot mode; prints final assistant text and exits |
| `--presenter NAME` | Interactive presenter: `tui` or `web` (default: `tui`). The web presenter serves `http://127.0.0.1:8765/` and requires LuaSocket. |
| `--continue` | Resume the most recent session for the current working directory |
| `--no-session` | Do not write a transcript to disk |
| `--skill PATH` | Additional skill file or directory (repeatable) |
| `--skills DIR` | Backward-compatible alias for `--skill DIR` |
| `--extension PATH` | Load an external extension file or directory (repeatable). Directories expect `init.fnl` or `init.lua`. See [`docs/extensions.md`](docs/extensions.md). |
| `--dev-path DIR` | Single-file binary only: prepend a Lua module source root; consumed by the launcher before `fen.main` loads. |
| `--extension-root DIR` | Single-file binary only: walk a root for flat extension manifests; used by `bin/fen-dev`. |

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
| `/reload` | Hot-reload core modules; under `bin/fen-dev` this reads edited `.fnl` directly |
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
| `FEN_AUTH_DIR` | Override fen's writable Codex `auth.json` directory. Default write path is `${XDG_CONFIG_HOME:-~/.config}/fen/auth.json`. |
| `PI_CODING_AGENT_DIR` | Add a pi-mono-compatible Codex `auth.json` read fallback. Fen never writes this path unless you explicitly point `FEN_AUTH_DIR` at the same directory. |
| `FEN_LOG` | `debug` \| `info` \| `warn` \| `error` (default `info`). Logs go to stderr; safe during the TUI. |
| `AGENT_FENNEL_RETRY` | Set to `0` to disable provider HTTP auto-retry regardless of CLI/provider options. |
| `FEN_EXTENSIONS_PATH` | Colon-separated extension discovery roots. See [`docs/extensions.md`](docs/extensions.md). |
| `FEN_ROCKS_TREE` | Override the fen-managed rocks tree used by `fen ext build` and extension dependency loading. |
| `FEN_BIN` | `bin/fen-dev` only: path to the single-file `fen` binary to use instead of `fen` on `PATH`. |
| `FEN_DEV_PATH` | Single-file binary: colon-separated Lua module roots prepended ahead of the embedded archive. |
| `FEN_EXTENSION_ROOT` | Single-file binary: colon-separated roots walked for flat extension manifests. |

## Distribution

The preferred distribution artifact is the production single-file binary:

```sh
nix build .#fen
./result/bin/fen --help
```

The output also includes a release-named copy at
`result/bin/fen-<version>-linux-x86_64`. Cross-built single-file artifacts are
available from x86_64 Linux:

```sh
nix build .#fen-linux-aarch64
nix build .#fen-linux-armv7-gnueabihf
```

The single-file binary embeds Lua 5.4, fen's compiled Lua modules, `fennel.lua`,
and Fen's production native modules: `cjson`, `termbox2`, `fen_http`, and
`fen_process`. `fen_http` links a minimal static libcurl/OpenSSL stack for HTTP
and HTTPS provider calls. No separate Lua rocks or Fen-owned `.so` modules are
needed for standard TUI usage. The web presenter is intentionally not part of
the first single-file runtime because it depends on LuaSocket; use a source
checkout/dev shell for `--presenter web`.

The current single-file artifact has no Nix store references. Inspect the
remaining glibc dynamic dependency floor with:

```sh
ldd ./result/bin/fen
strings ./result/bin/fen | grep /nix/store
zipinfo ./result/bin/fen    # if your unzip supports appended ZIP archives
```

HTTPS verification uses the host's normal certificate store, or the
`SSL_CERT_FILE` / `CURL_CA_BUNDLE` environment variables when a custom CA bundle
is needed.

`nix build` / `nix build .#fen` produces the single-file binary at
`result/bin/fen`, and `nix run .# -- --help` runs it directly. Cross-built
single-file binaries are exposed from x86_64 Linux as `.#fen-linux-aarch64` and
`.#fen-linux-armv7-gnueabihf`.

To run the cross-built ARM binaries directly under QEMU from an x86_64 host:

```sh
nix run .#fen-aarch64-qemu -- --help
nix run .#fen-armv7-qemu -- --help
```

Arguments after `--` are passed to fen, for example:

```sh
nix run .#fen-armv7-qemu -- --no-session --print hi
```

To smoke-test the current host's single-file binary in a scratch Docker image:

```sh
nix run .#dockerSmoke
```

To smoke-test a specific Linux target, build and load that target's image. On
non-native hosts, Docker also needs binfmt/QEMU support for the target platform:

```sh
nix build .#packages.aarch64-linux.scratchImage
img=$(docker load < result | sed -n 's/Loaded image: //p' | tail -1)
docker run --rm --platform linux/arm64 "$img" --help

nix build .#packages.armv7l-linux.scratchImage
img=$(docker load < result | sed -n 's/Loaded image: //p' | tail -1)
docker run --rm --platform linux/arm/v7 "$img" --help
```

To load the current host image as `fen:dev` without running it:

```sh
nix run .#loadDockerDev
docker run --rm fen:dev --help
```

For Codex auth in the container, mount the auth directory (same shape
fen and pi-mono both write to):

```sh
docker run --rm \
  -e PI_CODING_AGENT_DIR=/auth/pi-agent \
  -v "$HOME/.pi/agent:/auth/pi-agent" \
  fen:dev --provider openai-codex --no-session --print hi
```

The image is scratch-based and carries the single-file `fen` binary, the glibc
loader/runtime needed by that binary, static BusyBox applets on `PATH`, `/tmp`,
and CA certificates.

The old generated-tree launchers, wrapped Lua package output, and portable
Nix runtime tarball have been retired from the public flake surface. Use
`bin/fen-dev` for checkout development and `nix build .#fen` for the runtime
artifact.

The optional web presenter (`--presenter web`) uses LuaSocket to serve a tiny
local HTML page plus Server-Sent Events. Standard TUI usage does not require
LuaSocket; if the web presenter is selected without it, fen exits with
`web presenter requires luasocket`.

The TUI is built on [termbox2](https://github.com/termbox/termbox2), a small
single-header terminal library. There's no published `lua-termbox2` rock, so
the binding is vendored in-tree at
`extensions/tui/vendor/lua_termbox2.c` +
`extensions/tui/vendor/termbox2.h` and compiled to
`extensions/tui/dist/termbox2.so` by the Nix/package build path. The
installed launcher adds that package directory to `LUA_CPATH` so
the binding loads alongside the Fennel-compiled Lua. fen's libcurl wrapper
follows the same pattern: the C source lives in
`packages/util/vendor/fen_http.c` and compiles to
`packages/util/dist/fen_http.so`. These shared objects are still used by
source-checkout tests and non-binary development. The single-file binary
internalizes Fen's production runtime modules (`cjson`,
`termbox2`, `fen_http`, `fen_process`) for standard TUI usage.

## Extensions

Extensions can add slash commands, tools, hooks, system-prompt fragments, event
subscribers, presenters, status-bar items, and panels. External extensions are loaded from
`$FEN_EXTENSIONS_PATH`, XDG config roots, or explicit `--extension <path>`.
See [`docs/extensions.md`](docs/extensions.md) for the manifest format,
registration API, reload behavior, and examples.

## Built-in tools

`bash`, `read`, `write`, `ls`, `edit`, `grep`, `find`. They are registered by
the first-party `builtin_tools` extension
(`extensions/builtin-tools/`) using the same extension API external
tools use. Shared execution helpers stay in `packages/core/src/fen/core/tools.fnl`.
`edit` takes
`{path, edits: [{old_string, new_string}]}` with multi-edit support, exact
match, and overlap detection. `grep` and `find` shell out to POSIX
`grep`/`find` (no `rg`/`fd` dependency). Add new built-in tools by adding the
tool implementation under `extensions/builtin-tools/` and registering
it from that extension.

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
ship one and release artifacts don't bundle it.

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

## Adding a provider

For a provider that doesn't fit OpenAI Chat Completions or Anthropic Messages
(e.g. Gemini), add a provider extension:

1. Add a flat-layout extension under `extensions/<provider-name>/` (or ship an
   external extension) with a `manifest.fnl` and `init.fnl`.
2. Add a provider module beside it exporting at minimum
   `{:api :provider :complete :convert-messages :convert-tools
     :map-stop-reason :parse-response}`.
3. In the extension body, call `api.register :provider` with a spec that
   includes `:name`, `:api`, `:default-model`, and either `:api-key-var` or an
   `:auth-backend` registered with `api.register :auth-backend`.
4. Add wire-conversion tests under the extension's `tests/` directory.

The agent loop and tool registry don't change — they speak only canonical
types.

## ChatGPT Plus/Pro Codex subscription

`--provider openai-codex` lets you run fen against your ChatGPT
subscription instead of `OPENAI_API_KEY`-billed `/v1/responses`. fen ships
its own native PKCE login, so pi-mono is no longer required. Fen writes
its own credentials to `${XDG_CONFIG_HOME:-~/.config}/fen/auth.json` by
default, while treating pi-mono's `~/.pi/agent/auth.json` as a read-only
fallback so existing pi-mono users keep working unchanged.

Setup:

```sh
# 1. Run the OAuth login flow once. Prints an authorization URL; paste
#    the redirected localhost URL (or just the `code=...` value) back in.
fen --login openai-codex

# 2. Use Codex normally.
fen --provider openai-codex --print "what is 2+2?"
```

The browser will fail to load the `localhost:1455` redirect (we don't run a
local callback server) — that's expected. The address bar contains the code,
which is all we need.

Token refresh is lazy: when a request would otherwise go out with a token
expiring in the next 60 seconds, we POST to `auth.openai.com/oauth/token`,
extract the new `chatgpt_account_id` from the access JWT, and write the new
record back to fen's writable `auth.json` atomically. If the token came from
a pi-mono fallback file, refresh still writes only the fen-owned file.

Use `fen --logout openai-codex` to remove fen's stored record. It does not
remove pi-mono fallback credentials.

For relocated auth dirs, set `FEN_AUTH_DIR` to change fen's write path, or
`PI_CODING_AGENT_DIR` to add a pi-mono-compatible read fallback. `/status`
shows `auth: subscription (oauth)` plus the write path and read fallback
paths, so you can tell at a glance which files the live agent is using.

## Status

Three OpenAI-shape providers (Chat Completions, Responses, Codex subscription),
Anthropic Messages, native streaming with delta event coalescing in the TUI,
cooperative HTTP, full-screen termbox2 TUI, session persistence, custom
OpenAI-compatible providers, skills/project-context loading, lightweight
Markdown rendering, and a native Codex PKCE login flow. Canonical types and
provider seams mirror pi-mono's shapes; open roadmap items such as richer
session/model UX and tool batching are tracked in GitHub issues and extend
additively. See
`/home/anthony/.claude/plans/in-agent-fennel-i-want-wise-iverson.md` for the
original design boundary.
