# fen

A small AI coding-agent CLI written in [Fennel](https://fennel-lang.org/) and
compiled to Lua, built as a reloadable microkernel: a tiny core (agent loop,
canonical types, provider dispatch, extension registry) with providers, the UI,
session storage, and even the built-in tools all shipped as first-party
extensions.
Targets Lua 5.4 on ARMv7/Raspberry-Pi-class hardware.

Its core abstractions are modeled on [pi-mono]; see [Acknowledgments](#acknowledgments).

[pi-mono]: https://github.com/badlogic/pi-mono

## Status

Fen currently includes:

- OpenAI Chat Completions, OpenAI Responses, OpenAI Codex OAuth/subscription, and Anthropic providers
- custom OpenAI/Anthropic-compatible providers via `~/.config/fen/models.json`
- full-screen termbox2 TUI plus `stdio`, `print`, and optional `web` presenters
- session persistence/resume, project context, skills, slash commands, and hot reload
- built-in coding tools: `bash`, `read`, `write`, `ls`, `edit`, `grep`, `find`
- first-party extension support for tools, commands, providers, presenters, hooks, prompt fragments, status items, panels, and docs

## Quick start

```sh
# Build the production single-file binary
nix build .#fen
./result/bin/fen --help
./result/bin/fen --version   # prints the embedded git/build stamp

# One-shot prompt
OPENAI_API_KEY=... ./result/bin/fen --print "say hi"

# Interactive TUI
OPENAI_API_KEY=... ./result/bin/fen
```

No Nix? `make fen` builds the same single-file binary against your system Lua
and libcurl (`build/fen`); see
[`docs/distribution.md`](docs/distribution.md#building-without-nix).

Common provider setup:

```sh
# OpenAI API key providers
export OPENAI_API_KEY=...
fen --provider openai --print "say hi"
fen --provider openai-responses --print "say hi"

# Anthropic
export ANTHROPIC_API_KEY=...
fen --provider anthropic --print "say hi"

# ChatGPT/Codex subscription OAuth
fen --login openai-codex
fen --provider openai-codex --print "say hi"
```

Run `fen --help` for the authoritative CLI, slash-command, and environment
variable list.

## TUI notes

The transcript follows the live bottom by default.
Use Page Up or the mouse wheel to scroll back; new streamed content stays below the locked viewport and the status row shows `↓new` when unread content is available.
Use `ctrl-g` to jump to the latest user message from the live bottom or the previous user message above a scrolled viewport; repeat it to walk backward through older user messages.
Use `ctrl-y` to jump directly back to the live bottom and resume following.
Use Page Down until the scroll offset reaches zero to return to the live bottom and resume following incrementally.
Tool calls render as compact status rows and completed tool results fold into the matching `tool> ok|err ... (metadata)` row by default.
Use `/expand` or `ctrl-o` to toggle expanded tool-result body previews when debugging large outputs.

## Development

Normal development uses a single-file binary with source overlays. Edit `.fnl`
files, then run `/reload` in the live agent; do not rebuild generated `dist/`
trees for routine source edits.

```sh
# Reproducible binary, then source-checkout dev run
make dev-nix

# Or reuse an existing binary from PATH / FEN_BIN
make dev
FEN_BIN=/path/to/fen scripts/dev/fen-dev --print "say hi"
```

Fast checks:

```sh
fennel scripts/test/fennel-check.fnl
make test                         # full Busted suite
make test TESTS=packages/core/tests/extensions/loader_test.fnl
make smoke-mock                   # deterministic provider/tool/retry smoke
make check                        # fennel-check + tests
```

Reproducible/build checks:

```sh
nix build .#fen
nix flake check
```

Beyond the agent itself, the `fen` binary doubles as a portable runtime:

| command | purpose |
| --- | --- |
| `fen run SCRIPT [ARG...]` | Run a Lua or Fennel script with Fen's embedded runtime. |
| `fen eval CODE [ARG...]` | Evaluate inline Lua or Fennel code with Fen's embedded runtime. |
| `fen ext build DIR` | Build an extension rockspec into Fen's managed rocks tree. |

See [`docs/scripts.md`](docs/scripts.md) for the script runner and
[`docs/distribution.md`](docs/distribution.md) for `make` targets.

## Documentation

This README is intentionally short. Longer docs live in `docs/`:

- [`docs/development.md`](docs/development.md) — dev workflow, hot reload, checks
- [`docs/architecture.md`](docs/architecture.md) — module map, canonical types, microkernel, design principles
- [`docs/extensions.md`](docs/extensions.md) — extension discovery, manifests, API, reload behavior
- [`docs/providers.md`](docs/providers.md) — provider interface and custom `models.json` providers
- [`docs/tools.md`](docs/tools.md) — built-in tool contracts
- [`docs/sessions.md`](docs/sessions.md) — JSONL session format and resume flags
- [`docs/scripts.md`](docs/scripts.md) — portable Lua/Fennel script runner and eval
- [`docs/distribution.md`](docs/distribution.md) — binaries, cross builds, Docker smoke, releases
- [`docs/skills.md`](docs/skills.md) — skill discovery and prompt exposure

Runtime docs are also available inside the agent with `/docs` and to tools via
`fen_docs`.

## Distribution

The preferred artifact is the Nix-built single-file executable
(`nix build .#fen`); cross-built aarch64/ARMv7 Linux artifacts are exposed from
x86_64 Linux. See [`docs/distribution.md`](docs/distribution.md) for the full
artifact matrix, the single-file binary format, and the release workflow, and
[`docs/architecture.md`](docs/architecture.md) for the source-tree module map.

## Acknowledgments

fen's core contracts — canonical message types, the provider seam, the agent
loop, and the steering/follow-up model — are modeled on [pi-mono] by Mario
Zechner, the primary reference during fen's design.
fen is an independent Fennel/Lua reimplementation with its own architecture: it
inverts pi-mono's fat-core/thin-plugin layout into a small reloadable kernel
with providers, presenters, sessions, and tools delivered as extensions.
pi-mono is MIT-licensed.

fen is developed with heavy AI assistance.
Most code and docs were written with Claude (Opus 4.7, via Claude Code); once
fen could self-host development, GPT-5.5 was run through fen itself.
The architecture, design decisions, and review judgment are human-directed.

## License

Fen is licensed under the MIT License. See [`LICENSE`](LICENSE).
