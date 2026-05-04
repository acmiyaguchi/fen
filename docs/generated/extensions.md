# Fen extension contributions

Discovered `(api.register :kind {...})` sites across the
first-party extensions and core. Names extracted from
literal `:name` fields; dynamic registrations show the
source path with the name omitted.

## :auth-backend

- `openai-codex` — ChatGPT subscription PKCE OAuth credentials shared with the Codex CLI. — _extensions/provider-openai-codex/init.fnl:36_

## :command

- `reload-extension` — Reload one external extension by name — _extensions/builtin-commands/commands/extension.fnl:253_
- `extensions` — Pick an extension and show its detail panel — _extensions/builtin-commands/commands/extension.fnl:283_
- `help` — Show available commands and controls — _extensions/builtin-commands/commands/help.fnl:91_
- `model` — Switch model (overlay if no arg; index/name/substring if given) — _extensions/builtin-commands/commands/model.fnl:120_
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
- `handoff` — Summarize this session, seed a fresh session with the summary — _extensions/handoff/init.fnl:106_
- `mem` — Toggle the memory diagnostics panel; /mem gc forces a GC pass — _extensions/mem/init.fnl:237_
- `expand` — Toggle full vs collapsed tool-result bodies — _extensions/tui/init.fnl:334_
- `markdown` — Toggle Markdown rendering of assistant text — _extensions/tui/init.fnl:349_
- `thinking` — Show or hide assistant thinking blocks — _extensions/tui/init.fnl:365_

## :control

- `toggle-tool-results` — Toggle tool-result bodies — _extensions/tui/init.fnl:316_
- `toggle-thinking-blocks` — Toggle thinking blocks — _extensions/tui/init.fnl:322_
- `quit` — Quit; ctrl-c also clears input or cancels a busy turn — _extensions/tui/init.fnl:328_

## :panel

- _(dynamic)_ —  — _extensions/builtin-commands/commands/extension.fnl:293_
- _(dynamic)_ —  — _extensions/builtin-commands/commands/prompt.fnl:112_
- _(dynamic)_ —  — _extensions/builtin-commands/commands/queue.fnl:173_
- _(dynamic)_ —  — _extensions/builtin-commands/commands/status.fnl:148_
- _(dynamic)_ —  — _extensions/mem/init.fnl:248_
- _(dynamic)_ —  — _extensions/tui/init.fnl:287_
- `busy` — Web presenter spinner row shown while the agent is busy. — _extensions/web/init.fnl:148_

## :presenter

- `print` —  — _extensions/print/init.fnl:28_
- `tui` —  — _extensions/tui/init.fnl:295_
- `web` —  — _extensions/web/init.fnl:156_

## :provider

- _(dynamic)_ —  — _extensions/provider-anthropic/init.fnl:17_
- _(dynamic)_ —  — _extensions/provider-openai-codex/init.fnl:45_
- _(dynamic)_ —  — _extensions/provider-openai/init.fnl:18_
- _(dynamic)_ —  — _extensions/provider-openai/init.fnl:21_

## :session-backend

- `jsonl` — Append-only JSONL session backend under XDG state. Records canonical messages, replayable via --continue / /resume. — _extensions/session-jsonl/init.fnl:9_

## :status

- `model` —  — _extensions/tui/init.fnl:226_
- `context` —  — _extensions/tui/init.fnl:235_
- `steering-queue` —  — _extensions/tui/init.fnl:244_
- `follow-up-queue` —  — _extensions/tui/init.fnl:254_
- `attention` —  — _extensions/tui/init.fnl:264_
- `scroll` —  — _extensions/tui/init.fnl:275_
- `model` —  — _extensions/web/init.fnl:101_
- `context` —  — _extensions/web/init.fnl:110_
- `steering-queue` —  — _extensions/web/init.fnl:119_
- `follow-up-queue` —  — _extensions/web/init.fnl:129_
- `attention` —  — _extensions/web/init.fnl:139_

## :tool

- `agent_state` — Read structured state of the running agent. Read-only; does not evaluate code. Query is a tiny Fennel-shaped data language. Examples: (:get :model), (:count (:get :messages)), (:get :messages -1), (:pluck (:get :tools) :name), (:get :extensions :panels), (:where (:get :messages) :role :assistant), (:last (:where (:get :messages) :role :assistant)), (:slice (:get :messages) -5 5), (:keys (:get)). Prefer narrow queries over dumping large roots. Output defaults to JSON; use format=fennel for Fennel rendering when available. — _extensions/agent-state/init.fnl:14_
- _(dynamic)_ —  — _extensions/builtin-tools/init.fnl:14_
