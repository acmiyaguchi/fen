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
bin/fen-dev                                  Source-checkout dev wrapper for fenSingle
bin/fen                                      Compatibility POSIX launcher for dist trees
examples/models.json                         Copy-paste config for Ollama / Ollama Cloud
```

## Quickstart (Nix, canonical dev workflow)

Build the single-file runtime once, then drive the source checkout through
`bin/fen-dev`. The wrapper passes `--dev-path` for package source trees and
`--extension-root` for flat first-party extensions, so `.fnl` edits are compiled
on demand and picked up by `/reload` without `make build`.

```sh
nix build .#fenSingle
FEN_BIN=$PWD/result/bin/fen bin/fen-dev
```

One-shot examples use the same wrapper while developing:

```sh
OPENAI_API_KEY=sk-... FEN_BIN=$PWD/result/bin/fen bin/fen-dev --print "say hi in three words"
OPENAI_API_KEY=sk-... FEN_BIN=$PWD/result/bin/fen bin/fen-dev --provider openai-responses --print hi
ANTHROPIC_API_KEY=sk-ant-... FEN_BIN=$PWD/result/bin/fen bin/fen-dev --provider anthropic --print hi
ANTHROPIC_API_KEY=sk-ant-... FEN_BIN=$PWD/result/bin/fen bin/fen-dev --provider anthropic --thinking-budget 2048
# ChatGPT Plus/Pro subscription (run `pi login openai-codex` once first):
FEN_BIN=$PWD/result/bin/fen bin/fen-dev --provider openai-codex --print hi
OPENAI_API_KEY=sk-... FEN_BIN=$PWD/result/bin/fen bin/fen-dev              # interactive TUI
OPENAI_API_KEY=sk-... FEN_BIN=$PWD/result/bin/fen bin/fen-dev --presenter web  # browser UI
```

Fast local checks are still useful while editing:

```sh
nix develop
make fennel-check
make test
```

`nix flake check` is the canonical reproducible CI/check surface.

## Legacy / compatibility workflows

These commands remain available, but are no longer the preferred dev loop:

| command | status | purpose |
| --- | --- | --- |
| `nix build .#fenSingle` | canonical dev runtime / future distribution | Build the single-file binary used by `bin/fen-dev`. |
| `FEN_BIN=... bin/fen-dev` | canonical dev | Run directly from `.fnl` source overlays; `/reload` sees edits without generated `dist/`. |
| `nix flake check` | canonical CI | Reproducible checks. |
| `make fennel-check` | fast local check | Strict compile/global check for `.fnl` source and tests. |
| `make test` | fast local check | Run busted tests. |
| `make build` | compatibility/internal | Generate package `dist/` trees for the POSIX launcher and current Nix package/tarball plumbing. |
| `bin/fen` | compatibility | POSIX launcher over generated `dist/` trees and local rocks. |
| `make install-local` / `luarocks make` | packaging/internal | Local rock install smoke and package/extension publishing details. User-facing extension deps are planned for `fen ext build` in #68. |
| `make dist` | legacy | Older lightweight tarball assembled from generated `dist/` trees. |

### LuaRocks without Nix

The non-Nix path currently requires `lua5.4`, `luarocks`, `make`, and libcurl +
headers (`libcurl-dev` / `curl-devel`):

```sh
make install-local
OPENAI_API_KEY=sk-... bin/fen --print hi
```

Treat this as a compatibility/package smoke path until #68 moves extension
dependency builds behind `fen ext build`.

## CLI options

| option | meaning |
| --- | --- |
| `--provider NAME` | `openai`, `openai-responses`, `openai-codex`, `anthropic`, or any name defined in `~/.config/fen/models.json` (default: saved setting, else `openai`) |
| `--model NAME` | Model id. Defaults to saved setting when present; otherwise `gpt-5.4-nano` for openai / openai-responses, `gpt-5.5` for openai-codex, `claude-sonnet-4-6` for anthropic, or the first entry under `models` for a custom provider |
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
| `/reload` | Hot-reload core modules; under `bin/fen-dev` this reads edited `.fnl` directly, while the legacy dist-tree path requires `make build` first |
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
| `FEN_BIN` | `bin/fen-dev` only: path to the single-file `fen` binary to use instead of `fen` on `PATH`. |
| `FEN_DEV_PATH` | Single-file binary: colon-separated Lua module roots prepended ahead of the embedded archive. |
| `FEN_EXTENSION_ROOT` | Single-file binary: colon-separated roots walked for flat extension manifests. |

## Distribution

The long-term preferred artifact is the production single-file binary, tracked
by #66 and built today as the `fenSingle` prototype:

```sh
nix build .#fenSingle
./result/bin/fen --help
```

Until #66 fully embeds/native-registers the production C module set, the Nix
package and portable tarball remain the stable release baseline.

`nix build` produces a runnable Nix package at `result/bin/fen`, and
`nix run .# -- --help` runs it directly. This is the reproducible package
baseline used for current release work.

`nix build .#dist` produces a same-architecture Linux bundle tarball such as
`result/fen-<version>-linux-x86_64.tar.gz`. It includes Lua 5.4, fen's compiled
Lua modules, first-party Lua C modules, and shared libraries copied from the
Nix runtime closure. Extract it on a Linux host with the same architecture/ABI
and run `bin/fen` from the extracted directory. This bundle is intended to be
portable across Linux distributions without installing Lua rocks manually.

Release bundle attributes are exposed for all supported Linux targets:

```sh
# Native x86_64 Linux bundle.
nix build .#packages.x86_64-linux.dist

# Native/remote/emulated aarch64 Linux bundle.
nix build .#packages.aarch64-linux.dist

# Native/remote/emulated 32-bit ARMv7 hard-float glibc bundle.
nix build .#packages.armv7l-linux.dist
```

The resulting artifact names include OS, architecture, and ABI where relevant:

- `fen-<version>-linux-x86_64.tar.gz`
- `fen-<version>-linux-aarch64.tar.gz`
- `fen-<version>-linux-armv7-gnueabihf.tar.gz`

On x86_64 Linux, ARM release bundles can also be cross-built without binfmt or
remote ARM builders:

```sh
# Cross-built aarch64 Linux bundle.
nix build .#packages.x86_64-linux.dist-linux-aarch64

# Cross-built 32-bit ARMv7 hard-float glibc bundle.
nix build .#packages.x86_64-linux.dist-linux-armv7-gnueabihf
```

The cross-built artifacts use the same release names as the native builds.
They compile target Lua/C modules with Nixpkgs cross toolchains, then assemble
the portable bundle from the target runtime closure without running target
binaries during the build. Release bundles also include `fennel.lua`, copied as
architecture-independent Lua source from the build host, so `.fnl` extensions
work in cross-built ARM tarballs without depending on a target Fennel wrapper.

The ARMv7 target is Nix's `armv7l-linux`: 32-bit ARMv7, little-endian, glibc,
hard-float (`gnueabihf`). From a non-ARM host, native target attributes still
require either a matching remote builder or Linux binfmt/QEMU support so Nix can
execute target binaries during native package builds and smoke tests. On NixOS,
the minimal local QEMU setup is:

```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" "armv7l-linux" ];
nix.settings.extra-platforms = [ "aarch64-linux" "armv7l-linux" ];
```

If Nix reports `platform mismatch` for `aarch64-linux` or `armv7l-linux`, the
local machine has no usable native, remote, or emulated builder for that target;
configure one and rerun the same `nix build .#packages.<system>.dist` command.

The portable bundle has Nix smoke checks that run `bin/fen --help` from the
bundled tree. Native target smoke checks need binfmt/QEMU or a matching remote
builder:

```sh
nix build .#checks.aarch64-linux.distSmoke
nix build .#checks.armv7l-linux.distSmoke
```

Cross-built ARM bundles have x86_64-hosted QEMU smoke checks that do not require
binfmt registration:

```sh
nix build .#checks.x86_64-linux.qemuSmoke-linux-aarch64
nix build .#checks.x86_64-linux.qemuSmoke-linux-armv7-gnueabihf
```

To run the cross-built ARM bundles directly under QEMU from an x86_64 host:

```sh
nix run .#fen-aarch64-qemu -- --help
nix run .#fen-armv7-qemu -- --help
```

Arguments after `--` are passed to fen, for example:

```sh
nix run .#fen-armv7-qemu -- --no-session --print hi
```

To smoke-test the current host's portable bundle in a scratch Docker image:

```sh
nix run .#dockerSmoke
```

To smoke-test a specific Linux target, build and load that target's image. On
non-native hosts, Docker also needs binfmt/QEMU support for the target platform:

```sh
nix build .#packages.aarch64-linux.distScratchImage
img=$(docker load < result | sed -n 's/Loaded image: //p' | tail -1)
docker run --rm --platform linux/arm64 "$img" --help

nix build .#packages.armv7l-linux.distScratchImage
img=$(docker load < result | sed -n 's/Loaded image: //p' | tail -1)
docker run --rm --platform linux/arm/v7 "$img" --help
```

To load the current host image as `fen:dev` without running it:

```sh
nix run .#loadDockerDev
docker run --rm fen:dev --help
```

For Codex auth in the container, mount pi-mono's auth directory:

```sh
docker run --rm \
  -e PI_CODING_AGENT_DIR=/auth/pi-agent \
  -v "$HOME/.pi/agent:/auth/pi-agent" \
  fen:dev --provider openai-codex --no-session --print hi
```

The image is scratch-based but includes the portable fen bundle, static BusyBox
applets on `PATH`, `/tmp`, and CA certificates.

`make dist` produces the older lightweight `fen-dist.tar.gz` from generated
`dist/` trees. Treat it as a legacy compatibility artifact while Nix tarballs
and the single-file runtime mature. Untar it on a target host that has
`lua5.4`, libcurl, and runtime rocks (`lua-cjson` and optional `luasocket` for
`--presenter web`) installed, then run `bin/fen`. The launcher sets
`LUA_PATH`/`LUA_CPATH` to find compiled Lua under package `dist/` trees and
any rocks installed under a local `lua_modules/` tree alongside the launcher.

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
`packages/extensions/tui/dist/termbox2.so` by the compatibility `make build`
path. The POSIX launcher adds that package dist directory to `LUA_CPATH` so
the binding loads alongside the Fennel-compiled Lua. fen's libcurl wrapper
follows the same pattern: the C source lives in
`packages/util/vendor/fen_http.c` and compiles to
`packages/util/dist/fen_http.so`. The Nix release bundle attributes above
build both `.so` files plus `lua-cjson` against the selected target's libcurl
and Lua; non-Nix cross-arch deployment still means rebuilding C modules on
the target. The production single-file work in #66 will internalize these
runtime modules so this generated-dist path is no longer the primary artifact.

## Extensions

Extensions can add slash commands, tools, hooks, system-prompt fragments, event
subscribers, presenters, status-bar items, and panels. External extensions are loaded from
`$FEN_EXTENSIONS_PATH`, XDG config roots, or explicit `--extension <path>`.
See [`docs/extensions.md`](docs/extensions.md) for the manifest format,
registration API, reload behavior, and examples.

## Built-in tools

`bash`, `read`, `write`, `ls`, `edit`, `grep`, `find`. They are registered by
the first-party `builtin_tools` extension
(`packages/extensions/builtin-tools/`) using the same extension API external
tools use. Shared execution helpers stay in `packages/core/src/fen/core/tools.fnl`.
`edit` takes
`{path, edits: [{old_string, new_string}]}` with multi-edit support, exact
match, and overlap detection. `grep` and `find` shell out to POSIX
`grep`/`find` (no `rg`/`fd` dependency). Add new built-in tools by adding the
tool implementation under `packages/extensions/builtin-tools/` and registering
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
