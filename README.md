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

- OpenAI Chat Completions, OpenAI Responses, OpenAI Codex OAuth/subscription, and Anthropic providers
- custom OpenAI/Anthropic-compatible providers via `~/.config/fen/models.json`
- full-screen termbox2 TUI plus `stdio`, `print`, and optional `web` presenters
- session persistence/resume, project context, skills, slash commands, and hot reload
- built-in coding tools: `bash`, `read`, `write`, `ls`, `edit`, `grep`, `find`
- first-party extension support for tools, commands, providers, presenters, hooks, prompt fragments, status items, panels, and docs

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

# One-shot prompt
OPENAI_API_KEY=... ./result/bin/fen --print "say hi"

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

The transcript follows the live bottom by default.
Use Page Up/Page Down or the mouse wheel to scroll the transcript; new streamed content stays below the locked viewport and the status row shows `↓new` when unread content is available.
Mouse-wheel scrolling is on by default, which asks the terminal to forward mouse events to fen.
Because fen receives those events, it also handles copy itself: click and drag over the transcript to select text, and on release fen copies the selection to your system clipboard via the OSC 52 escape (the status row briefly shows `copied <n>B`).
OSC 52 travels from fen out to your local terminal, so it works over SSH and mosh as long as the terminal supports it (foot, and Blink on iOS, do).
If your terminal ignores OSC 52 or you prefer native terminal selection, set `FEN_TUI_MOUSE=0` (also accepts `off`/`false`/`no`) to turn mouse capture off and restore your terminal's own click-drag selection and copy/paste; you lose only wheel scrolling (Page Up/Page Down still work).
Use `ctrl-g` to jump to the latest user message from the live bottom or the previous user message above a scrolled viewport; repeat it to walk backward through older user messages.
Use `ctrl-y` to jump directly back to the live bottom and resume following.
Use Page Down until the scroll offset reaches zero to return to the live bottom and resume following incrementally.
Tool calls render as compact status rows and completed tool results fold into the matching `tool> ok|err ... (metadata)` row by default.
Use `/expand` or `ctrl-o` to toggle expanded tool-result body previews when debugging large outputs.
Use `ctrl-l` (or `/redraw`) to force a full repaint and recover when another process or a terminal/tmux glitch corrupts the screen; scroll position and the input buffer are preserved.
Use `ctrl-z` to suspend fen to the shell like any full-screen app, then `fg` to resume — the terminal is restored on suspend and re-initialized on return.

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
| `fen update` | Replace the installed release binary with the latest GitHub release (verified, atomic). |

See [`docs/scripts.md`](docs/scripts.md) for the script runner and
[`docs/distribution.md`](docs/distribution.md) for `make` targets.

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
