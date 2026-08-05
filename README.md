# fen

A small AI coding-agent CLI written in [Fennel](https://fennel-lang.org/) and
compiled to Lua, built as a reloadable microkernel: a tiny core (agent loop,
canonical types, provider dispatch, extension registry) with providers, the UI,
session storage, and even the built-in tools all shipped as first-party
extensions.
Targets Lua 5.4 on ARMv7/Raspberry-Pi-class hardware.

Its core abstractions are modeled on [pi-mono]; see [Acknowledgments](#acknowledgments).

[pi-mono]: https://github.com/badlogic/pi-mono

![fen reading its own README and describing itself in the TUI](docs/assets/demo.gif)

## Status

Fen currently includes:

- OpenAI Chat Completions, OpenAI Responses, OpenAI Codex OAuth/subscription, Anthropic, and Sakana AI providers
- custom OpenAI/Anthropic-compatible providers via `~/.config/fen/models.json`
- full-screen termbox2 TUI plus `stdio`, `print`, `json`, and `web` presenters
- session persistence/resume, project context, skills, slash commands, and hot reload
- built-in coding tools: `bash`, `read`, `write`, `ls`, `edit`, `grep`, `find`, plus `tool_search` and `fen_docs` for on-demand discovery
- first-party extensions can register tools, commands, providers, presenters, session backends, auth backends, hooks, status items, panels, and more; see [`docs/extensions.md`](docs/extensions.md)

## Install

Linux x86_64/aarch64/armv7 — download the latest prebuilt static binary:

```sh
curl -fsSL https://acmiyaguchi.github.io/fen/install.sh | sh
```

It picks the right release asset, verifies its checksum, and installs to
`~/.local/bin/fen` (override with `FEN_BIN_DIR`; pin a tag with `FEN_VERSION`).
See [`docs/distribution.md`](docs/distribution.md#install-script) for details and
the manual-download equivalent. On other platforms, build from source below.

## Quick start

```sh
# Build the production single-file binary
nix build .#fen
./result/bin/fen --help
./result/bin/fen --version   # prints the embedded git/build stamp

# Discover live capabilities without starting a session or contacting an LLM
./result/bin/fen list tools --json
./result/bin/fen list models --provider openai --json

# One-shot prompt (stdin and hard tool restrictions are also supported)
OPENAI_API_KEY=... ./result/bin/fen --print "say hi"
git diff | ./result/bin/fen --print - --tools read,grep,find,ls --no-session

# Headless bounded objective (0=done, 2=blocked/incomplete, 1=failure)
OPENAI_API_KEY=... ./result/bin/fen goal --max-iterations 5 "fix the failing tests"

# Interactive TUI
OPENAI_API_KEY=... ./result/bin/fen

# Docker scratch image, mounted on the current directory
OPENAI_API_KEY=... nix run .#dockerRun -- --print "say hi"
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

Key reference:

| key | effect |
| --- | --- |
| Page Up/Down, mouse wheel | scroll the transcript; `↓new` in the status row marks unread streamed content |
| click-drag, release | select transcript text and copy it via OSC 52 (works over SSH/mosh) |
| `ctrl-g` / `ctrl-y` | jump to the latest/previous user message; jump back to the live bottom |
| `ctrl-o` (or `/expand`) | toggle expanded tool-result previews |
| `ctrl-l` (or `/redraw`) | force a full repaint after terminal corruption |
| `ctrl-z` | suspend to the shell; `fg` restores the TUI |

Mouse capture is on by default; set `FEN_TUI_MOUSE=0` to restore your terminal's native selection at the cost of wheel scrolling.
See [`docs/tui.md`](docs/tui.md) for the full design guide: spatial model, copy/paste tradeoffs, recovery behavior, extension affordances, and testing direction.

## Development

Normal development uses a single-file binary with source overlays. Edit `.fnl`
files, then run `/reload` in the live agent; do not rebuild generated `dist/`
trees for routine source edits.

```sh
make dev-nix                      # nix build .#fen, then source-checkout dev run
make check                        # static checks + full test suite
```

[`docs/development.md`](docs/development.md) is the source of truth for the
workflow: the hot-reload loop, the fast/slow test split, smoke and profiling
harnesses, and contribution flow.

Beyond the agent itself, the `fen` binary doubles as a portable runtime:

| command | purpose |
| --- | --- |
| `fen goal [OPTIONS] OBJECTIVE` | Run the `/goal` companion headlessly with a bounded iteration count. |
| `fen session new\|list\|show\|send\|doctor` | Blocking JSON subprocess interface for durable sessions. |
| `fen list [SURFACE]` / `fen show SURFACE NAME` | Offline discovery of commands, tools, providers, models, and more. |
| `fen providers [NAME]` | Provider setup pages without starting the TUI. |
| `fen run SCRIPT [ARG...]` | Run a Lua or Fennel script with Fen's embedded runtime. |
| `fen eval CODE [ARG...]` | Evaluate inline Lua or Fennel code with Fen's embedded runtime. |
| `fen ext build DIR` | Build an extension rockspec into Fen's managed rocks tree. |
| `fen update` | Replace the installed release binary with the latest GitHub release (verified, atomic). |

Headless `--print`, JSON presenter, and `goal` runs write flushed progress lines to stderr while keeping stdout reserved for the final result.

See [`docs/sessions.md`](docs/sessions.md) for the session interface,
[`docs/scripts.md`](docs/scripts.md) for the script runner, and
[`docs/distribution.md`](docs/distribution.md) for `make` targets and releases.

## Documentation

This README is intentionally short. Longer docs live in `docs/`, indexed by
[`docs/README.md`](docs/README.md), which maps each guide to its audience
(running fen, contributing, internals, extensions, providers) and points at the
generated API/contract reference.

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
