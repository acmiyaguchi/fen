# Roadmap and scope

Open follow-ups and intentional omissions. Where an item has an issue, follow
that plan rather than treating this file as a veto; closed history lives in git
and GitHub.

## Tracked follow-ups

- **Distribution hardening** — #62, #64, #123. The single-file Nix binary, cross
  Linux artifacts, scratch Docker smoke, and tag releases have landed; remaining
  work is artifact-policy hardening and compatibility decisions.
- **Provider streaming** — #24. Cooperative HTTP and first-party OpenAI/Anthropic
  SSE reduction exist; further work is scoped per provider/presenter.
- **Codex auth refresh** — token refresh lives in
  `extensions/adapters/providers/openai/openai_codex_oauth.fnl`. The auth-backend
  record carries optional `:login!` / `:logout!` (dispatched by
  `--login` / `--logout`). Credentials are read/written only at
  `${XDG_CONFIG_HOME:-~/.config}/fen/auth.json` (or `FEN_AUTH_DIR/auth.json`); fen
  does not read pi/`~/.pi/agent/auth.json`.
- **Bash cancel semantics** — #80. Killing a silent long-running child before
  `pclose()` blocks is still pending.
- **Tool batching** — #120. Read/edit batch shapes exist; write batching and true
  concurrent tool execution in one turn remain.
- **Sandbox policy** — #15, #19. Belongs in an opt-in extension, not core tools.
- **Embedded REPL** — #20.
- **Native-rock support for static artifacts** — #70.

## Intentionally out of scope

Unless a new issue asks for it: image input and image MIME/base64 handling, a
full model-pricing/cost registry, full CommonMark/browser-style rendering, code
syntax highlighting, `fd`/`rg` hard runtime dependencies, and wholesale pi-mono
feature parity.
