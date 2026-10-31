# Context: prompt-prefix caching and usage accounting

Model: [`model.qnt`](model.qnt).
Scope: one session as a sequence of provider requests.
A request is abstracted as (visible tool list, system-prompt version, context message ids), and every message has a block count that stands in for both its wire content blocks and its tokens.
Response usage is `{input, output, cacheRead, cacheWrite, total}`.
The provider is either `anthropic` (explicit `cache_control` breakpoints, tools rendered before system before messages, a breakpoint reads an earlier cache entry only within a lookback window `W`) or `openai` (automatic prefix caching).
Environment actions: user turn, provider request with 0, 1 or 2 tool calls, tool results (optionally a `tool_search` activation), cancel at a yield, compaction (idle `/compact` or auto, or the `compact` tool mid-loop), single-extension reload, agent rebuild that re-renders the system prompt (`/reload`, `/thinking`, `/handoff`), provider switch, and `--continue` replay at startup.
Ghost state folds every `:llm-end` usage on the bus (`bus`, which is exactly the TUI's `cum-*` fold) and counts tool calls and results.
Retry attempts reuse the view in [`spec/network`](../network/FINDINGS.md): a request here is the last attempt.

Code: `packages/core/src/fen/core/agent.fnl` (`visible-tools`, `build-context`, `build-options`, `step-loop`, cancel pairing), `extensions/adapters/providers/anthropic/anthropic_messages.fnl` (`build-body`, `mark-last-message-cache!`, `convert-messages`, `parse-response`, `merge-usage!`), `extensions/adapters/providers/openai/openai_completions.fnl` (`usage->canonical`), `extensions/adapters/providers/openai/openai_responses_shared.fnl` (`extract-usage`), `extensions/adapters/providers/openrouter/openrouter_completions.fnl` (`add-cache-breakpoints!`), `packages/util/src/fen/util/{tokens,usage,turn_result}.fnl`, `extensions/behaviors/companions/compact/init.fnl` (`finish-compact!`), `extensions/adapters/presenters/rpc/init.fnl` (`run-messages`, `messages-from`, `turn-ended!`, `finish!`), `extensions/adapters/presenters/json/init.fnl`, `packages/fen/src/fen/session_control.fnl` (turn usage), `extensions/behaviors/companions/subagent/{init,runs}.fnl` (`apply-usage-telemetry!`, `accumulate-usage!`), `extensions/adapters/presenters/tui/ingest.fnl` (`:llm-end`), `extensions/behaviors/inspectors/status/commands/status.fnl`, `packages/core/src/fen/core/extensions/register/tool.fnl`, `packages/core/src/fen/core/extensions/loader/init.fnl` (`reload-extension!`).

Probes were run once through `make test TESTS=…` and then deleted:
`extensions/behaviors/companions/compact/tests/zz_probe_context_compact_test.fnl`, `extensions/adapters/presenters/rpc/tests/zz_probe_context_rpc_test.fnl`, `extensions/adapters/presenters/json/tests/zz_probe_context_json_test.fnl`, `extensions/adapters/providers/anthropic/tests/zz_probe_context_cache_test.fnl`, `extensions/adapters/providers/openai/tests/zz_probe_context_total_test.fnl`.
Every probe reported `0 failures / 0 errors`; the lines quoted below are their output.

## Bugs

### #617: Compaction rewrites the usage history: session totals drop, and the summary call is never in them

Counterexample (`sessionUsageComplete`): `init(replayed) → userTurn → requestTool → compactTool`.
Every message-derived total (`tokens.usage-totals`, `turn-result.sum-usage`) sums `usage` over `agent.messages`.
`finish-compact!` replaces `agent.messages` with `[summary] ++ kept`, so the usage of every summarized assistant message disappears from `/status` "reported usage".
The summary call's own usage is emitted only as `:llm-end` and never stored on a message, so the TUI's cumulative counters include it while `/status`, the wire result and the JSON blob do not.
Totals are therefore neither monotone nor equal to each other.

Confirmed: real `/compact` with a stubbed summary call (`input 30000`) over `[user(big), asst(input 22000), user, asst(input 100, cache-read 44500)]`:
```
PROBE usage-totals.input before=22100 after=100
PROBE llm-end usage.input on bus during compaction=30000
```

### #618: Wire turn and run usage are index slices of a history that compaction rewrites

Counterexample (`runUsageExact`): same trace as #617.
The rpc presenter records `run-start-index` and each turn's `start-index` as positions in `agent.messages` and sums `sum-usage` over the suffix for `turn-complete` and `result`.
After an in-run compaction (the `compact` tool, or auto-compaction on a tick) the positions point into a shorter, different list, so assistant turns before the old index are skipped; if the list shrinks below the index the usage is absent.
The subagent parent then makes it worse: `apply-usage-telemetry!` replaces its event-derived total (which saw every `:llm-end`, including compaction) with the child's smaller `result` usage and marks it `usage-complete? true`.
`fen session send` slices the same way (`copy-suffix agent.messages (+ replayed 1)`), by trace.

Confirmed: real rpc presenter, real agent loop and real `compact` tool on the mock provider, six seeded messages, prompt `go`; the run made calls of input 1000 (tool call), 30000 (summary) and 10 (answer):
```
PROBE turn-complete usage.input=10.0
PROBE result usage.input=10.0
PROBE sum of forwarded llm-end usage.input=31010.0
```

### #619: Headless JSON usage includes the whole `--continue` history

Counterexample (`headlessUsageExact`): `init(replayed)`, no steps needed.
`session-lifecycle.start!` appends replayed messages to `agent.messages`, and the JSON presenter reports `(turn-result.sum-usage messages)` over all of them (and dumps all of them as `messages`).
`fen session send` already slices from `replayed + 1`; the JSON presenter has no replay offset.

Confirmed: JSON presenter over one replayed exchange (`total-tokens 50900`) plus a new turn (`total-tokens 10`):
```
PROBE json usage.total-tokens=50910.0 input=50007.0 messages=4
```

### #620: After compaction the old context size is shown as exact

Counterexample (`exactContextIsCurrent`): `init(replayed) → userTurn → requestTool → compactTool`.
`tokens.context-token-info` takes the latest assistant message with non-zero usage as the provider-reported baseline and calls it exact when it is the last message.
Compaction keeps the recent assistant messages with their usage, which describes the pre-compaction context.
So `/status` and every `update-queue-status!` refresh (run on each `:message-appended`) report the old size as `provider-reported` until the next request, while compaction's own hint (`tokens-after`, messages only) says otherwise.
The same mechanism applies after an agent rebuild that changes the system prompt or tokenizer (`/model`, `/reload`), by trace only.

Confirmed (same probe as #617):
```
PROBE context before=44650 provider-reported after=44650 provider-reported estimated?=false
PROBE set-status-info approx-context hint=46
PROBE full estimate after=46
```

### #621: `total-tokens` means different things per provider

Counterexample (`totalTokensConvention`): `init(openai) → userTurn → requestText → userTurn → requestTool` (the second request reads the first from cache).
`fen.util.usage` documents `total-tokens` as excluding cache tokens (input + output), and Anthropic follows it.
`openai_completions` and `openai_responses_shared` keep the provider's `total_tokens`, which includes cached prompt tokens; a gateway that omits `total_tokens` yields `0`, which `usage-totals` keeps because `0` is truthy in Lua.
Sums across a provider switch mix the two meanings; `/status`, JSON `usage.total-tokens` and `subagent` `summarize-usage` show them.

Confirmed (`parse-response` of both adapters, 20 uncached + 80 cached + 5 output):
```
PROBE openai-completions usage: input=20 cache-read=80 output=5 total-tokens=105
PROBE anthropic usage:          input=20 cache-read=80 output=5 total-tokens=25
PROBE gateway without total_tokens: total-tokens=0
PROBE usage-totals over both: total-tokens=130 (input+output=50)
```

### #622: Reloading one extension reorders the always-visible tools and silently breaks the whole cached prefix

Same root cause as [extensions #626](../extensions/FINDINGS.md) (list registrations move to the end on reload); this is its prompt-cache cost.

Counterexample (`prefixStableUnlessNamed`): `userTurn → requestText → reloadExtension → userTurn → requestText`.
`#603` sorts activated search tools, but always-visible tools keep registry order, and `reload-extension!` runs `unregister-by-owner` and re-registers, which appends that owner's tools at the end of `tools-extra`.
The rebuilt agent sends the same tools in a new order; tools precede system and messages, so nothing cached is reused even when the extension changed nothing.
The search-tool catalogue in the system prompt (`available-tools-section`) iterates the same order.
A full `/reload` re-registers every extension in discovery order, so it restores the original order; scoped reloads (`only-names`) and enable/disable do not.

Confirmed (agent on the mock provider, tools from owners `ext-a`, `ext-b`, `ext-c`; then what `reload-extension!` does for `ext-a`):
```
PROBE request tools before reload: read,bash,grep
PROBE request tools after  reload: bash,grep,read
```

### #623: One moving message breakpoint: a large tool round loses the cached history

Counterexample (`cacheReuseOnExtension`): `userTurn → requestParallelTools → toolResults → requestTool` (anthropic, `W = 4` scaled).
`build-body` marks the system prompt, the last tool and the last block of the last message, three of the four allowed breakpoints.
The next request's only message breakpoint sits after the new assistant blocks and tool results; Anthropic looks back only about 20 blocks from a breakpoint for an earlier cache entry.
A round with ten parallel tool calls adds 21 blocks, so request n+1 misses request n's entry and rewrites the whole history at the 1h write price (2x base input).
OpenRouter's Anthropic/Google path has the same single tail breakpoint.

Confirmed in code (`am.build-body` for `[user, asst(text + 10 tool_use), 10 tool results]` and the same plus one more such round):
```
PROBE cache_control markers: req1=3 req2=3
PROBE message blocks: req1=22 req2=43 => blocks between req1 breakpoint and req2 breakpoint=21
PROBE req2 still marks req1's tail? false
```
The ~20-block lookback is Anthropic's documented behavior and was not exercised against the live API (no network).

## What holds

- `breakpointsWithinLimit`: at most 3 `cache_control` markers on Anthropic (2 on OpenRouter); history-stub tools and tool-less compaction requests carry fewer.
  Coalesced user messages copy only canonical `cache_control`, which nothing sets, and every converter copies blocks, so `mark-last-message-cache!` never mutates `agent.messages`.
- `toolPairing`: every tool call gets exactly one result (normal, failed, edit-conflict, refused under `:tool-choice :none`, cancelled serial or parallel), and each call emits exactly one `:tool-call` event, so `subagent` `tool-call-count` matches.
- Every reported provider call emits exactly one `:llm-end`, so the TUI `cum-*` counters equal the sum of reported usage, and no adapter counts cache reads or writes as input (Anthropic reports them separately; both OpenAI adapters subtract them from `prompt_tokens`; the TUI adds them back only for `last-input`).
- Side-chat (`/btw`) usage goes to its workspace's `ws.usage`, never to the main bus or `agent.messages`.
- Cancel and errored turns do not break the prefix: the empty `:aborted` marker and `:error` turns are dropped from context, and the dangling user message coalesces with the next one on Anthropic without changing earlier blocks.

### Prefix break points (all intended, none documented as cache costs)

| Action | What changes | Cost on Anthropic |
| --- | --- | --- |
| `tool_search` activation | tool list (sorted search tools after always-visible) | tools precede everything: full history rewrite at 2x |
| compaction | history | full rewrite (expected) |
| `/reload`, `/thinking`, `/handoff`, extension toggle | agent rebuilt, system prompt re-rendered (date, context files, skills) | full rewrite whenever any fragment changed, e.g. after midnight |
| `/model`, provider switch | new model or provider cache | cold cache |
| `/new`, `/resume` | `prompt-cache-key` (OpenAI) | new key |
| single-extension reload | tool order (#622) | full rewrite, unintended |

## Candidate fix (modelled as `fixed`)

- A per-session usage ledger fed by every `:llm-end` (turn, compaction, and retries if attempts ever report usage); `/status`, the wire `turn-complete`/`result`, the JSON blob and `session send` report ledger deltas between markers taken at turn/run start, never message slices. Replayed usage seeds the ledger for session totals only.
- `context-token-info` ignores usage reported before the latest history rewrite or agent rebuild (an epoch stamp), falling back to the estimate.
- Adapters normalize `total-tokens` to `input + output` (derive it when the provider omits it).
- A canonical always-visible tool order that does not depend on registration order (for example by name, as search tools already are).
- On Anthropic, re-mark the previous request's tail when it is still a prefix (4 of 4 breakpoints: tools, system, previous tail, new tail), so the previous entry is always an exact hit.

All invariants hold under `fixed`.

## Core

The domain needs two small things.
A request is an immutable prefix `(tools, system, history)` plus an epoch that bumps at the named break points; breakpoints are a pure function of (previous request, this request), and the context-size baseline is valid only within the current epoch.
Usage is a ledger with one entry per provider call, keyed by call kind (turn, compaction, side chat), and every view (TUI counters, `/status`, wire, JSON, subagent rollup) is a fold of that ledger between markers.
Today usage lives on assistant messages and each consumer re-derives totals from whichever slice of `agent.messages` it holds, which is why compaction, replay and index drift each break a different total.
Storing usage on messages can stay as display data, but it should not be the accounting source.

## Property-test follow-ups

- Only Responses `function_call` arguments use `json.encode-deterministic`.
  Tool parameter schemas, Anthropic `tool_use.input` and Chat Completions `function.arguments` go through `cjson.encode` in table-hash order, which can differ across processes (Lua string-hash seeds) and across `/reload` (fresh schema tables), silently changing the tools prefix or replayed history bytes.
  A property test: encode the same request built twice from fresh tables (and after a decode/encode round trip of a session) and compare bytes.
- Number formatting of tool arguments replayed from a session (`1` vs `1.0` after JSON decode in Lua 5.4) against the original request bytes.

## Open questions

- Cancelled requests and failed retry attempts never report usage: the provider's partial stream state (Anthropic `message_start` already carries input and cache usage) is discarded when `CANCEL-MARKER` unwinds, so billed tokens are missing from every total. Not probed.
- Compaction and side-chat requests reuse the session's `prompt-cache-key` (`build-options` resolves it from the session id) with prefixes unrelated to the main conversation, which may dilute OpenAI's cache routing. Not measured.
- The `subagent` `max-turns` budget counts compaction's `:llm-end` as a turn.
- `fen goal` with `FEN_JSON_OUTPUT_PATH` writes no `usage`, although `docs/sessions.md` calls it "the existing JSON-presenter result blob".
- After compaction the TUI keeps `context-estimated? false` (set by the summary call's `:llm-end`) while `approx-context` is the messages-only estimate `tokens-after`, which also leaves out system and tool tokens. By trace.
- A tool-result batch followed by an injected steering message produces two consecutive `user` wire messages on Anthropic (`convert-messages` coalesces user-after-user and result-after-result, not result-then-user). The API currently merges consecutive same-role turns; not verified.
