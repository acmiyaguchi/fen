# CLAUDE.md

Project-specific notes for Claude Code sessions in this repo. See `README.md`
for end-user docs.

## What this is

A small AI coding-agent CLI written in Fennel, compiled to Lua. Conceptually
mirrors pi-mono's module shape (LLM client → agent loop → TUI) in vastly
simplified form. Targets Lua 5.4 on ARMv7 (Raspberry Pi-class hardware).

## Module map

```
src/main.fnl           CLI entry: arg parse, dispatch print|interactive
src/core/llm.fnl       OpenAI Chat Completions over lua-curl
src/core/agent.fnl     Agent loop: prompt → llm → tool_calls → exec → loop
src/core/tools.fnl     Tool registry + built-ins (bash/read/write/ls)
src/tui/tui.fnl        ANSI escapes + stty raw -echo. No curses.
src/util/json.fnl      lua-cjson wrapper
src/util/log.fnl       Leveled stderr logger (AGENT_FENNEL_LOG)
bin/agent-fennel       POSIX-sh launcher, sets LUA_PATH/LUA_CPATH
```

Compiled `.lua` lands in `dist/` mirroring `src/` layout. `dist/` is
gitignored — don't check it in.

## Workflow

```sh
nix develop                # dev shell
make build                 # fennel --compile src/**/*.fnl → dist/
make test                  # offline shape tests
bin/agent-fennel --help    # launcher smoke check
```

Edit `.fnl` only; never hand-edit `dist/*.lua`. Rebuild after every Fennel
change before running.

## Conventions / gotchas

- **Provider is OpenAI**, not Anthropic. Reads `OPENAI_API_KEY`. Endpoint is
  Chat Completions (`/v1/chat/completions`), tool calling via the
  `tools` / `tool_calls` / `role:"tool"` round-trip.
- **lua-curl module name is `cURL`** (capital U, capital R, capital L), even
  though the rock is `lua-curl`. See `core/llm.fnl`.
- **lua-cjson module name is `cjson`** (rock `lua-cjson`). See `util/json.fnl`.
- **Don't reintroduce lcurses.** It caps at Lua `<5.4`, isn't in nixpkgs as a
  Lua 5.4 rock, and forces a 5.2 toolchain. The TUI is intentionally
  ANSI+stty so deployment to a fresh ARM box only needs `lua-curl` +
  `lua-cjson`.
- **Raw mode breaks `\n`.** When the TUI is active, `stty raw` is on, so a
  bare `\n` won't return the carriage. `tui.fnl` uses CRLF (`\r\n`) — keep
  doing that for any new TUI output.
- **Tests run under busted** with the `--loaders=lua,fennel` flag, which
  enables busted's built-in Fennel loader for the test files themselves. A
  `tests/busted-helper.lua` script (passed via `--helper`) extends
  `fennel.path` with `src/` so test files can `(require :core.llm)` etc. and
  resolve directly to Fennel source — no `make build` first.
  Important: extend `fennel.path`, NOT `package.path`. If `.fnl` paths leak
  into `package.path`, the Lua searcher will find the file before the Fennel
  searcher and try to parse Fennel as Lua.
- **Mock modules in tests via `package.loaded`** before requiring the module
  under test. `core/agent.fnl` does `(local llm (require :core.llm))` at load
  time, so `tests/agent_test.fnl` sets `package.loaded["core.llm"]` to a fake
  before its own `(require :core.agent)`. Avoids needing constructor-injection
  refactors in production code.
- **Launcher is POSIX sh** (no bashisms). It needs to run on whatever the
  Pi ships. Don't add `[[`, `${var,,}`, arrays, etc.
- **Tool descriptors are built lazily** in `core/tools.fnl#descriptors` —
  the registry stores `{:description :parameters :execute}` and
  `descriptors` translates to the OpenAI `{:type "function" :function {…}}`
  shape on each LLM call. New tools just append to `registry`.
- **Agent has a 16-turn safety cap** in `core/agent.fnl#step` to bound
  pathological tool-call loops. Bump if a real workflow needs more, don't
  remove.
- **`make-agent` accepts a `:convert-to-llm` callback** —
  `(messages → messages)`. Default identity. Mirrors pi-mono's `convertToLlm`
  seam: callers can carry custom message shapes in `agent.messages` and
  project them to OpenAI wire shape only on the way out. Don't bake provider
  conversion in here yet — it's the entry point for that work when it lands.

## Out of scope (don't add unless asked)

Streaming SSE, multi-provider, OAuth, thinking blocks, image input, session
persistence, edit/grep/find tools, markdown rendering. The original plan in
`/home/anthony/.claude/plans/in-agent-fennel-i-want-wise-iverson.md` lists
the boundary in full.

## Distribution shape

`make dist` tarballs `dist/` + `bin/` + `README.md`. End user needs `lua5.4`
+ `lua-curl` + `lua-cjson` on the target. The launcher prepends a local
`lua_modules/` tree to `LUA_PATH`/`LUA_CPATH`, so users can ship rocks
alongside the launcher when system rocks aren't available.
