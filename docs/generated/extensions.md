# Fen extension contributions

Discovered `(api.register :kind {...})` sites across the
first-party extensions and core. Names extracted from
literal `:name` fields; dynamic registrations show the
source path with the name omitted.

## :auth-backend

- `openai-codex` — ChatGPT subscription PKCE OAuth credentials shared with the Codex CLI. — _extensions/provider-openai-codex/init.fnl:35_

## :command

- `reload-extension` — Reload one external extension by name — _extensions/builtin-commands/commands/extension.fnl:253_
- `extensions` — Pick an extension and show its detail panel — _extensions/builtin-commands/commands/extension.fnl:283_
- `help` — Show available commands and controls — _extensions/builtin-commands/commands/help.fnl:91_
- `model` — Switch model (overlay if no arg; index/name/substring if given) — _extensions/builtin-commands/commands/model.fnl:118_
- `prompt` — Toggle the prompt-fragments panel; /prompt rendered emits the rendered prompt — _extensions/builtin-commands/commands/prompt.fnl:102_
- `queue` — Toggle the queue panel; /queue clear|mode preserve their actions — _extensions/builtin-commands/commands/queue.fnl:144_
- `cancel-all` — Cancel current turn and clear queues — _extensions/builtin-commands/commands/queue.fnl:159_
- `new` — Reset the current conversation and start a fresh session — _extensions/builtin-commands/commands/session.fnl:160_
- `reload` — Hot-reload core modules and source overlays — _extensions/builtin-commands/commands/session.fnl:214_
- `n` — Alias for /new — _extensions/builtin-commands/commands/session.fnl:246_
- `sessions` — Pick a recent session to resume (overlay) — _extensions/builtin-commands/commands/session.fnl:253_
- `resume` — Resume a session (overlay if no arg; id/prefix/path/index if given) — _extensions/builtin-commands/commands/session.fnl:259_
- `r` — Alias for /reload — _extensions/builtin-commands/commands/session.fnl:270_
- `status` — Toggle the status panel (model, provider, tokens, session) — _extensions/builtin-commands/commands/status.fnl:141_
- `docs` — Browse runtime docs: /docs [topic] [name] — _extensions/docs/init.fnl:423_
- `handoff` — Summarize this session, seed a fresh session with the summary — _extensions/handoff/init.fnl:93_
- `mem` — Toggle the memory diagnostics panel; /mem gc forces a GC pass — _extensions/mem/init.fnl:236_
- `expand` — Toggle full vs collapsed tool-result bodies — _extensions/tui/init.fnl:364_
- `markdown` — Toggle Markdown rendering of assistant text — _extensions/tui/init.fnl:380_
- `animations` — Toggle TUI busy animations — _extensions/tui/init.fnl:396_
- `thinking` — Show or hide assistant thinking blocks — _extensions/tui/init.fnl:413_

## :control

- `toggle-tool-results` — Toggle tool-result bodies — _extensions/tui/init.fnl:346_
- `toggle-thinking-blocks` — Toggle thinking blocks — _extensions/tui/init.fnl:352_
- `quit` — Quit; ctrl-c also clears input or cancels a busy turn — _extensions/tui/init.fnl:358_

## :panel

- _(dynamic)_ —  — _extensions/builtin-commands/commands/extension.fnl:293_
- _(dynamic)_ —  — _extensions/builtin-commands/commands/prompt.fnl:112_
- _(dynamic)_ —  — _extensions/builtin-commands/commands/queue.fnl:173_
- _(dynamic)_ —  — _extensions/builtin-commands/commands/status.fnl:148_
- _(dynamic)_ —  — _extensions/docs/init.fnl:455_
- _(dynamic)_ —  — _extensions/mem/init.fnl:247_
- _(dynamic)_ —  — _extensions/tui/init.fnl:317_
- `busy` — Web presenter spinner row shown while the agent is busy. — _extensions/web/init.fnl:147_

## :presenter

- `print` —  — _extensions/print/init.fnl:27_
- `stdio` —  — _extensions/stdio/init.fnl:243_
- `tui` —  — _extensions/tui/init.fnl:325_
- `web` —  — _extensions/web/init.fnl:155_

## :provider

- _(dynamic)_ —  — _extensions/provider-anthropic/init.fnl:16_
- _(dynamic)_ —  — _extensions/provider-openai-codex/init.fnl:44_
- _(dynamic)_ —  — _extensions/provider-openai/init.fnl:17_
- _(dynamic)_ —  — _extensions/provider-openai/init.fnl:20_

## :session-backend

- `jsonl` — Append-only JSONL session backend under XDG state. Records canonical messages, replayable via --continue / /resume. — _extensions/session-jsonl/init.fnl:8_

## :status

- `model` —  — _extensions/tui/init.fnl:256_
- `context` —  — _extensions/tui/init.fnl:265_
- `steering-queue` —  — _extensions/tui/init.fnl:274_
- `follow-up-queue` —  — _extensions/tui/init.fnl:284_
- `attention` —  — _extensions/tui/init.fnl:294_
- `scroll` —  — _extensions/tui/init.fnl:305_
- `model` —  — _extensions/web/init.fnl:100_
- `context` —  — _extensions/web/init.fnl:109_
- `steering-queue` —  — _extensions/web/init.fnl:118_
- `follow-up-queue` —  — _extensions/web/init.fnl:128_
- `attention` —  — _extensions/web/init.fnl:138_

## :tool

- `agent_state` — Read structured state of the running agent. Read-only; does not evaluate code. Query is a tiny Fennel-shaped data language. Examples: (:get :model), (:count (:get :messages)), (:get :messages -1), (:pluck (:get :tools) :name), (:get :extensions :panels), (:where (:get :messages) :role :assistant), (:last (:where (:get :messages) :role :assistant)), (:slice (:get :messages) -5 5), (:keys (:get)). Prefer narrow queries over dumping large roots. Output defaults to JSON; use format=fennel for Fennel rendering when available. — _extensions/agent-state/init.fnl:13_
- _(dynamic)_ —  — _extensions/builtin-tools/init.fnl:13_
- `fen_docs` — Read fen runtime docs and extension contracts. Useful for implementing extensions: inspect register kinds, canonical types, event shapes, and live commands/tools/providers. Topics: topics, commands, tools, providers, auth-backends, session-backends, presenters, controls, status, panels, prompt-fragments, events, types, register-kinds, interfaces, extensions. Use name for a specific entry, e.g. {topic:'register-kinds', name:'tool'} or {topic:'types', name:'ToolResultMessage'}. — _extensions/docs/init.fnl:440_
