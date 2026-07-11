# Copilot instructions for `fen`

`fen` is a small Fennel→Lua coding-agent CLI.
It mirrors pi-mono's interface shapes in simplified form and targets Lua 5.4 on
ARMv7/Raspberry-Pi-class hardware.

These are the repo-wide rules that apply to every changed file.
Path-scoped rules that add depth for specific subtrees live in
`.github/instructions/*.instructions.md` and are layered on top automatically.

Keep review comments concise and actionable.
Prefer targeted fixes over broad rewrites; don't request a rewrite unless it is warranted.
Only comment when there is a concrete failure scenario, and identify the smallest fix plus a missing regression test when applicable.
Prioritize correctness, data loss, hangs, and state-machine violations over naming or style.

## Review protocol

Review changed behavior end-to-end, including unchanged callers and consumers rather than only the edited lines.
When a PR links an issue, compare the implementation with its acceptance criteria and flag behavior that is only partially implemented or documented more strongly than the runtime supports.

For each new persisted field, API, event, or state transition, verify:

- producers and consumers agree on accepted types and version semantics;
- write success implies the value can be read back;
- malformed, missing, stale, and newer-version data fail safely;
- restart and reload do not reuse process-local identity;
- cancellation, retries, and duplicate events cannot revive completed work;
- session and owner boundaries prevent state leakage;
- long work is cooperative through a production-reachable call path.

For storage changes, review append, decode, validation, selection, caching, invalidation, discovery, and restore as one contract.

## Source model

- Source is **Fennel** (`.fnl`), compiled to Lua.
- Naming is kebab-case in Fennel ↔ camelCase in the pi-mono TypeScript it ports from;
  "what does pi-mono call this?" is a fair question for new interface shapes.

## Never touch

- Package `dist/` trees and any generated `.lua` — they are machine-generated and gitignored.
  Hand edits or check-ins of `dist/` are a bug.
- Committed `result` / `result-*` symlinks (disposable Nix build links).
- Sibling checkouts `pi-mono/` and `dirac/` are reference-only; PRs should not modify them.

## Cross-cutting dependency conventions

These bans hold anywhere in the tree, so flag them regardless of the file under review.

- All HTTP goes through `fen.util.http.request` and the in-tree `fen_http.so` binding.
  Flag any reintroduction of `lua-curl`.
- The TUI uses termbox2. Flag any reintroduction of `lcurses`.
- Launcher/build scripts are POSIX `sh`. Flag bashisms.

## Behavior changes need docs and tests

- A behavior change should update the relevant `docs/` page and carry or update tests.

## Architecture boundaries

These follow the design principles in `docs/architecture.md`; flag violations anywhere in the tree.

- **Canonical types stay inside; wire shapes stay at the boundary.**
  Agent-side code (agent loop, tools, prompt assembly, generic core) uses the canonical
  message/tool shapes from `packages/core/src/fen/core/types.fnl`.
  Flag provider-specific wire JSON leaking past the provider boundary.
- **Document stable public surface, keep helpers internal.**
  New canonical types, event shapes, register kinds, extension API helpers, and
  provider/session/auth interfaces should carry `;; @doc` blocks and matching generated docs;
  one-file helpers and internal state exports stay undocumented.
- **One spelling per command/API.**
  Don't add aliases, shims, legacy command spellings, or parallel helper APIs unless the
  change explicitly requires compatibility; delete shims when call sites move.
