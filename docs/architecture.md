# Architecture notes

The stable contracts, module layout, and design principles behind fen's core.
For the day-to-day workflow and the full hot-reload model see
[`development.md`](development.md); the auto-generated API and contract reference
is indexed by the [generated sitemap](sitemap.html).

## Module map

```
packages/util/src/fen/util/                 JSON, HTTP, SSE, path, process, checksum helpers
packages/core/src/fen/core/types.fnl        Canonical Message/Tool/StopReason shapes
packages/core/src/fen/core/llm/             Provider registry, model config, stream accumulator
packages/core/src/fen/core/agent.fnl        Agent loop over canonical messages
packages/core/src/fen/core/tools.fnl        AgentTool executor/helpers
packages/core/src/fen/core/prompt.fnl       System-prompt fragment assembly
packages/core/src/fen/core/extensions/      Extension API, registry, loader, events, persistent state
packages/core/src/fen/core/settings.fnl     User preferences (~/.config/fen/settings.json)
packages/fen/src/fen/main.fnl               CLI entry: arg parse, provider dispatch, extension bootstrap, subcommands
packages/fen/src/fen/interactive.fnl        Interactive presenter runtime: agent build, cooperative turn loop, presenter lifecycle
packages/fen/src/fen/run_state.fnl          Interactive presenter/runtime state table construction
packages/fen/src/fen/session_lifecycle.fnl  Session backend selection, resume, flush, close policy
packages/fen/src/fen/session_control.fnl    Exact-ID blocking session orchestration for subprocess adapters
extensions/adapters/providers/              OpenAI family (Chat/Responses/Codex), Anthropic Messages, shared provider transport skeleton (retry/backoff/streaming)
extensions/adapters/presenters/tui/         Full-screen termbox2 presenter (design: docs/tui.md)
extensions/adapters/session-backends/jsonl/ Append-only JSONL session backend
extensions/behaviors/kernel/                builtin-tools, default-prompt, essentials (/help, /model), docs (/docs), steering queues
extensions/behaviors/actions/sessions/      /new, /reload, /sessions, /resume
extensions/behaviors/inspectors/            status, queue, prompt, extensions panels
extensions/behaviors/companions/            skills, mem, agent-state, compact, todo, handoff, plan, simplify, subagent
scripts/dev/fen-dev                         Source-checkout dev wrapper for the single-file runtime
```

`fen.util.json` is the single JSON seam (encode/decode plus the `null`,
`empty_array`, and `array_mt` sentinels). Embedded hosts on the
`embedding-seams` track that substitute lua-cjson must provide the full API
surface documented at the top of `packages/util/src/fen/util/json.fnl`; run
`packages/util/tests/json_contract_test.fnl` against any substitute to confirm
it conforms (a partial substitute degrades silently).

`fen.util.http` and `fen.util.path` are injectable backend seams built the same
way: an `init` dispatches to a backend resolved via `require`, a `backend`
module selects the default, and hosts inject by pre-populating
`package.loaded` before first require. `fen.util.http` defaults to the
`fen_http.so` native transport; `fen.util.path` defaults to a POSIX backend
(`fen.util.path.backends.posix`) whose surface is `getenv`/`stat`/`list-dir`/
`pwd-physical` and keeps the lfs-preferred/`test`/`ls`/`pwd -P` behavior. The
public path helpers (home, XDG dirs, cwd, realpath, file/dir probes) derive
from that one backend, so an embedded host without a POSIX shell swaps the
backend rather than the API. Path grammar stays `/`-separated; a non-POSIX
separator is not a probe and would be a future backend concern.

`fen.util.clock`, `fen.util.process`, and `fen.util.random` follow the same
seam. `fen.util.clock` isolates the two clock primitives (`monotonic-ms`,
`sleep-ms`) that sit on the `agent.step` hot path, so `fen.core.agent` measures
latency through the clock alone and never requires the subprocess module; the
default backend (`fen.util.clock.backends.native`) wraps `fen_process`.
`fen.util.process` keeps its cooperative drain/timeout state machine but routes
the subprocess surface (`fileno`/`set_nonblock`/`read`/`close_fd`,
`spawn`/`spawn_shell`/`wait_pid`/`kill_process_group`, `setenv`, and the
EAGAIN/EWOULDBLOCK/SIGTERM/SIGKILL constants) through
`fen.util.process.backends.posix`. `fen.util.random` routes `bytes` through
`fen.util.random.backends.native` (the `fen_random.so` CSPRNG). An embedded or
WASM host injects any of these backends via `package.loaded` before first
require, so default CLI behavior is unchanged.

`fen.util.checksum` follows the same seam for the reload path's change
detection. Its default backend (`fen.util.checksum.backends.default`) resolves
a module to its on-disk source via `package.searchpath` + `io.open`; modules
loaded through a custom `package.searchers` entry (a host's in-VM compiler) are
invisible to `searchpath`, so `module-fingerprint` returns nil and the reload
loader is forced to reload-all every time. A host with such a loader swaps the
backend to supply a per-module version/etag, restoring incremental reload.
Relatedly, the reload loader's dev-overlay gate
(`fen.core.extensions.loader.reload`) reads `FEN_DEV_PATH` through the injectable
`fen.util.path` VFS `getenv` rather than `os.getenv` directly: a host without OS
env vars enables overlay candidate discovery by swapping the path backend,
reusing the existing env seam instead of adding a second one.

Extension discovery follows the same seam for enumerating the manifest list.
`fen.core.extensions.loader.discover` owns only the backend-independent policy
(priority ordering and name dedupe with shadowed-version annotations) and routes
the raw enumeration through an injectable backend
(`fen.core.extensions.loader.discover.backend`). The default backend
(`fen.core.extensions.loader.discover.backends.posix`) keeps the exact current
POSIX enumeration — explicit paths, `$FEN_FIRST_PARTY_EXTENSIONS_PATH`,
`.fen/extensions` cwd ancestry, `$FEN_EXTENSIONS_PATH` / XDG user roots, and
embedded first-party manifests — walked with POSIX `find` via `io.popen` and
`fen.util.path` probes. Its surface is a single `enumerate` entry point
(`(enumerate explicit-paths ?yield-fn) -> [spec]`). An embedded host with no
`find`, no cwd ancestry, and no filesystem injects its own backend before first
require to supply the discovered-manifest list directly, so it need not swap the
discover or loader modules. Discovery reruns on `/reload`; the discover module,
selector, and default backend are all core-reloadable, so a swapped backend
table stays in effect the same way the other seams do.

Config storage follows the same seam for persisting user preferences and
reading provider config.
`fen.core.storage` owns the single storage surface — reading a config document
and atomically writing one, keyed by a resolved path — and dispatches it
through an injectable backend (`fen.core.storage.backend`).
`fen.core.settings` (settings.json) and `fen.core.llm.models` (models.json)
resolve the XDG document location through `fen.util.path` and then read and
write bytes only through this seam, so JSON parsing, normalization, and
unknown-key preservation stay in the callers.
The default backend (`fen.core.storage.backends.default`) keeps the exact
prior XDG-file behavior: `io.open` reads that return nil for a missing file,
and a `mkdir -p` + temp-file + `os.rename` atomic write with `os.remove`
cleanup on failure.
Its surface is `read`/`write!`.
An embedded host that backs config with its own persistence injects its own
backend before first require, so it need not swap the settings or models
modules.
API-key credentials keep the existing precedence — the `auth-backend` registry
first, then the models.json `api-key-var` environment variable read through the
`fen.util.path` VFS `getenv` rather than `os.getenv` — reusing the env seam
rather than adding a second one.
The storage module, selector, and default backend are all core-reloadable, so a
swapped backend table stays in effect the same way the other seams do (note
`fen.core.settings` may be required early in bootstrap, so hosts inject the
backend before that first require).

The repo tree is authoritative if it ever disagrees with this summary.
Dependency graphs (per-module, per-extension, subsystem) are generated under
`docs/generated/graphs/`; the [graph summary](generated/graphs/summary.md) lists
cycles and fan-in/fan-out hot spots (regenerate with `make graphs`).
Compiled `.lua` for Nix builds lands in gitignored package `dist/` trees — don't
check those in or hand-edit them.

## Reloadable microkernel

fen is a tiny core (agent loop, canonical types, provider dispatch, extension
registry) with providers, the TUI, session storage, and the built-in tools all
shipped as first-party extensions. `/reload` re-runs module bodies in place, so
most code lives in reloadable modules.

The contract that keeps reload safe: persistent identity lives in a few
non-reloadable state modules — `fen.extensions.tui.state` (termbox lifecycle,
transcript, scroll), `fen.core.extensions.state` (event bus, registries, prompt
fragments), and `fen.main` — and their reloadable siblings read and write through
them. The full rules (what reloads, cooperative yielding, idempotent
registration) live in
[`development.md`](development.md#hot-reload-is-the-development-loop).

## Canonical types and pi-mono divergence

All agent-side code operates on canonical message/tool shapes defined in
`packages/core/src/fen/core/types.fnl`; the field-level reference is generated
from source rather than restated here. Providers convert to and from wire shape
at the boundary, so the agent loop never sees provider-specific JSON — the
wire-shape differences are documented in [`providers.md`](providers.md).

Field naming is kebab-case in Fennel (`:tool-call-id`, `:stop-reason`,
`:is-error?`), semantically identical to pi-mono's camelCase; wire shapes stay
snake_case for JSON over HTTP.

Deliberately skipped vs pi-mono (added back only when a feature needs them):
ImageContent, `response-id` / `textSignature` / `thoughtSignature`, `usage.cost`,
`executionMode` / `signal` / `onUpdate` on tools, and `prepareArguments` / TypeBox
schema validation. ThinkingContent is kept — both Anthropic extended thinking and
OpenAI reasoning models surface it.

## Design principles

These shape the core API and what the generated docs cover. They are values, not
signatures, so they don't drift with the code the way restated facts do.

- **Strong, concise contracts.** While the design is small and local, prefer one
  clear public entry point over aliases, shims, legacy slots, or "just in case"
  wrappers; delete compatibility shims when call sites move.
- **Prune dead and legacy code.** Code with no remaining callers, branches for
  retired behavior, and mechanisms superseded by a better one are deleted, not
  kept "in case".
  A change that obsoletes code removes it in the same PR unless the removal
  exceeds that PR's scope; deferred pruning is filed as an issue and linked
  from the PR body as `Refs #<n>`, so the debt is named and checkable, never
  silently carried.
  This extends "Strong, concise contracts" (which covers deleting shims when
  call sites move) from contract surface to all code.
- **One mechanism per job.** Reuse the events bus and existing register kinds
  before adding a new hook point, kind, queue, or reload path.
  Two overlapping mechanisms for one job is the failure mode this guards
  against (duplicated reload, hook-vs-events).
- **The core is the kernel only.** Agent loop, canonical types, provider
  dispatch, prompt assembly, tool execution, and the extension
  loader/registry/events belong in `packages/core`.
  Doc data, provider transport policy, and presenter logic live with their
  consumers.
- **Promote on second use.** A helper needed by two extensions moves to
  `fen.util.*` or a shared extension module rather than being copied;
  copy-paste is how the extension tree sprawls.
- **One spelling per command/API.** If `/prompt rendered` is the contract, don't
  also carry `/prompt full`, `--full`, or a `/prompt-fragments` alias.
- **Structured introspection.** Public metadata is named fields on records (a
  prompt fragment's `:id` / `:title` / `:description`), not text parsed back out
  of rendered output.
- **Narrow extension-facing surface.** Expose the smallest useful shape, and drop
  legacy concepts (prompt slots, per-slot render helpers) once a better
  abstraction lands.
- **Generated docs describe the supported surface, not every boundary-crossing
  helper.** Add `;; @doc` blocks for stable public contracts — canonical types,
  event shapes, register kinds, extension API helpers, provider/session/auth
  interfaces. Keep one-file helpers local; treat undocumented data/state exports
  as internal. Coverage is a signal, not the goal.
