# Roadmap and scope

Tracked work, intentional omissions, and historical scope notes.

## Roadmap and scope

The old v0 "out of scope" list has been split into issue-tracked work vs.
still-intentional omissions. If an item has an open issue, follow that plan
instead of treating this file as a veto.

Tracked / no longer blanket out-of-scope:
- **Distribution follow-ups** — #62, #63, #64, #123. The single-file Nix binary,
  scratch Docker smoke image, cross Linux artifacts, and tag-driven release
  workflow have landed. The `lua-curl` rock has been replaced with the in-tree
  `fen_http.so` libcurl binding (#65 closed). Remaining work is artifact policy
  hardening and any follow-up compatibility decisions.
- **Streaming / SSE provider events** — #24. Cooperative HTTP and first-party
  OpenAI/Anthropic SSE reduction have landed. Follow-up work should be scoped
  per provider or presenter rather than treating all provider streaming as
  absent.
- **Codex subscription / OAuth auth** — #23 closed; native PKCE login lives in
  `extensions/adapters/providers/openai/openai_codex_login.fnl` (`fen --login
  openai-codex`). The auth-backend record carries `:login!` / `:logout!`
  optional methods that `--login` / `--logout` dispatch through, so future
  providers can register the same hooks. Token refresh is still in
  `openai_codex_oauth.fnl`. Fen reads and writes Codex credentials only at
  `${XDG_CONFIG_HOME:-~/.config}/fen/auth.json` by default, or
  `FEN_AUTH_DIR/auth.json` when that override is set; it does not read
  `PI_CODING_AGENT_DIR/auth.json` or `~/.pi/agent/auth.json`.
- **Bash cancel semantics** — #80. TUI cancel is cooperative today, but killing
  a silent long-running child before `pclose()` blocks is still pending.
- **Tool batching / multi-tool turns** — #120 and related edit-serialization
  work. Read/edit batch shapes and explicit parallel tool-use prompting have
  landed; write batching and true concurrent tool execution inside one turn
  remain follow-ups.
- **Extension and sandbox work** — #15 and #19. Sandbox policy belongs in an
  opt-in extension, not core tool implementations.
- **Interactive model/session UX** — model switching has landed through
  `/model`; richer session management is planned additively.
- **Introspection/dev helpers** — `agent_state` and status version info have
  landed. The embedded REPL remains tracked separately (#20).

Already landed from that old list/roadmap: termbox2 full-screen TUI (#1),
cooperative TUI/HTTP responsiveness (#2), custom providers (#8), project
context/skills (#13), system-prompt resource assembly (#17), Markdown TUI
rendering (#11), tool-output fidelity/truncation spill files (#5/#6), streaming
provider events for first-party providers (#24), model switching, `agent_state`,
status version info, and the distribution baseline from #43 (`nix build`,
scratch Docker smoke image, cross artifacts, and tag releases).

Still intentionally out of scope unless a new issue asks for it: image input
and image MIME/base64 handling, full model-pricing/cost registry, full
CommonMark/browser-style rendering, code syntax highlighting, fd/rg hard
runtime dependencies, and wholesale pi-mono feature parity.

The original v0 boundary has since moved: sessions, skills, the termbox2 TUI,
Markdown rendering, custom providers, and the full pi-mono tool surface (as
scoped under "Tools" in `docs/tools.md`) are now in.


