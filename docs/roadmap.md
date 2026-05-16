# Roadmap and scope

Tracked work, intentional omissions, and historical scope notes.

## Roadmap and scope

The old v0 "out of scope" list has been split into issue-tracked work vs.
still-intentional omissions. If an item has an open issue, follow that plan
instead of treating this file as a veto.

Tracked / no longer blanket out-of-scope:
- **Distribution follow-ups** — #62, #63, #64. The single-file Nix binary and
  scratch Docker smoke image have landed; the `lua-curl` rock has been replaced
  with the in-tree `fen_http.so` libcurl binding (#65 closed). Remaining work is
  ARMv7/aarch64 artifact hardening and release automation.
- **Streaming / SSE provider events** — #24. Current HTTP is cooperative via
  `complete-coop` + `util.http`, but providers still aggregate complete
  non-streaming responses before parsing.
- **Codex subscription / OAuth auth** — #23 closed; native PKCE login lives in
  `extensions/adapters/providers/openai/openai_codex_login.fnl` (`fen --login
  openai-codex`). The auth-backend record carries `:login!` / `:logout!`
  optional methods that `--login` / `--logout` dispatch through, so future
  providers can register the same hooks. Token refresh is still in
  `openai_codex_oauth.fnl`. Fen reads and writes Codex credentials only at
  `${XDG_CONFIG_HOME:-~/.config}/fen/auth.json` by default, or
  `FEN_AUTH_DIR/auth.json` when that override is set; it does not read
  `PI_CODING_AGENT_DIR/auth.json` or `~/.pi/agent/auth.json`.
- **Bash cancel semantics** — #9. TUI cancel is cooperative today, but killing
  a silent long-running child before `pclose()` blocks is still pending.
- **Tool batching / multi-tool turns** — #26 and #27. Read/edit batch shapes
  and explicit parallel tool-use prompting are planned; true concurrent tool
  execution inside one turn remains a separate, not-yet-scoped change.
- **Extension and sandbox work** — #15 and #19. Sandbox policy belongs in an
  opt-in extension, not core tool implementations.
- **Interactive model/session UX** — #14 and #10. Model switching and richer
  session management are planned additively.
- **Introspection/dev helpers** — #20, #21, #22. REPL, `agent_state`, and
  status version info are tracked.

Already landed from that old list/roadmap: termbox2 full-screen TUI (#1),
cooperative TUI/HTTP responsiveness (#2), custom providers (#8), project
context/skills (#13), system-prompt resource assembly (#17), Markdown TUI
rendering (#11), tool-output fidelity/truncation spill files (#5/#6), and the
initial distribution baseline from #43 (`nix build`, scratch Docker smoke
image).

Still intentionally out of scope unless a new issue asks for it: image input
and image MIME/base64 handling, full model-pricing/cost registry, full
CommonMark/browser-style rendering, code syntax highlighting, fd/rg hard
runtime dependencies, and wholesale pi-mono feature parity.

The original v0 boundary has since moved: sessions, skills, the termbox2 TUI,
Markdown rendering, custom providers, and the full pi-mono tool surface (as
scoped under "Tools" in `docs/tools.md`) are now in.


