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

The bugs were first confirmed by throwaway probes (`zz_probe_context_*_test.fnl`, `0 failures / 0 errors`; the lines quoted below are their output).
Each now has a permanent `known-bug` probe against the real code (see "Evidence per bug").

## Input assumptions

What the environment actions of [`model.qnt`](model.qnt) can and cannot produce:

- Provider calls return 0, 1 or 2 tool calls; every message's block count stands in for both its wire blocks and its tokens, and history is bounded at `MAXM = 12` messages.
- A request is the last retry attempt; failed attempts and cancelled requests report no usage (see Open questions).
- Anthropic cache hits follow a scaled lookback window `W = 4`; OpenAI hits the longest cached prefix. Cache entries never expire (no TTL).
- Only one always-visible owner moves on a reload (a rotation of three tools), two search tools can be activated, the system prompt is re-rendered at most twice, and `--continue` replays at most one exchange, only at startup.
- Compaction keeps the messages from the last user boundary and its summary call reads every summarized block; it runs idle or as the compact tool with one pending call.

The proof models generate less:
[`proofs/prefix`](proofs/prefix/model.qnt) has only scalar prefix coordinates (tool order, activated tools, system render, history generation, history blocks) and never models usage; a compaction may leave any history size up to the current one.
[`proofs/ledger`](proofs/ledger/model.qnt) has at most 5 provider calls of 0 or 1 tool calls, cache reads of 0 or 1 tokens, an OpenAI gateway that may omit `total_tokens`, cancel, and compaction to any smaller size; it never models caching, tool order or provider switches.


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

Each fix is named after its issue (`FIXES`): `fixed` enables all seven, and each `fix<issue>` instance enables one; every issue's own invariant holds with its fix alone (sampled), so the seven fixes are independent.
All invariants hold under `fixed` (sampled).

## Proof models

The integration model mixes the two concerns, and its cache is a `Set[Key]` of list-valued keys, which is expensive for Apalache and irrelevant to accounting.
So the contracts are split:

- [`proofs/prefix`](proofs/prefix/model.qnt) (#622, #623): the request prefix as scalars. Between named breaks history only grows, so "extends" is equality of tool order, activated tools, system render and history generation plus `<=` on history blocks; the previous request's entry is read back exactly when a breakpoint is within `W` of it (Anthropic) or always (OpenAI).
- [`proofs/ledger`](proofs/ledger/model.qnt) (#617–#621): an append-only usage log, one entry per provider call (turns and compaction, plus the replayed usage as a seed), and markers for the run and the invocation; every view is a fold of the log from a marker. Today's design is the same log kept on the messages (`msgU`), which compaction rewrites and the presenters index into.

Measured with `SPEC_VERIFY_JOBS=1 JVM_ARGS=-Xmx3g` (Apalache 0.56.1):

| Model | Obligation | Kind | Result |
| --- | --- | --- | --- |
| prefix | `fix622.prefixInductive` (implies `prefixStableUnlessNamed`) | inductive | holds, 3 s |
| prefix | `fixed.cacheInductive` (adds `cacheReuseOnExtension`, `breakpointsWithinLimit`) | inductive | holds, 2 s |
| prefix | `fixed.allInvariants`, 8 steps | bounded-safe | holds, 2 s |
| ledger | `fixed.allInvariants`, 7 steps | bounded-safe | holds, 9 s |

The prefix strengthening is: unless a named break came since the previous request, the next request's prefix coordinates equal the previous one's and its history is strictly longer.
With the canonical tool order alone (#622) that is inductive, so prefix stability holds at any depth; the re-marked tail (#623) then makes every extension an exact hit within 4 breakpoints.
The ledger is a list, which Apalache cannot generate from an invariant, so it is bounded: every ledger counterexample is at most 3 steps, and 7 steps exhaust the 5-call bound. The same obligation at 12 steps also holds but takes 297 s, so the obligation stays at 7.
For both models, `current` gives an Apalache counterexample (checked once by hand), and the `current` and single-fix instances reproduce each bug as a `violated` row with a witness.

## Evidence per bug

| Bug | Counterexample (row) | Witness | Proof model | Probe (confirmed) |
| --- | --- | --- | --- | --- |
| #617 | `current.sessionUsageComplete`; ledger `current.sessionUsageComplete` | `w617CompactionDropsSessionUsageTest` (both) | ledger, bounded-safe for the fix | `extensions/behaviors/companions/compact/tests/issue_617_compaction_rewrites_usage_totals_test.fnl` |
| #618 | `current.runUsageExact`; ledger `current.runUsageExact` | `w618RunUsageIndexSliceTest` (both) | ledger | `extensions/adapters/presenters/rpc/tests/issue_618_run_usage_index_slice_test.fnl` |
| #619 | `current.headlessUsageExact`; ledger `current.headlessUsageExact` | `w619JsonUsageIncludesReplayTest` (both) | ledger | `extensions/adapters/presenters/json/tests/issue_619_json_usage_includes_replay_test.fnl` |
| #620 | `current.exactContextIsCurrent`; ledger `current.exactContextIsCurrent` | `w620StaleContextExactTest` (both) | ledger | `extensions/behaviors/companions/compact/tests/issue_620_stale_context_size_after_compaction_test.fnl` |
| #621 | `current.totalTokensConvention`; ledger `current.totalTokensConvention` | `w621TotalIncludesCacheTest` (both), `w621GatewayOmitsTotalTest` (ledger) | ledger | `extensions/adapters/providers/openai/tests/issue_621_total_tokens_convention_test.fnl` |
| #622 | `current.prefixStableUnlessNamed`; prefix `current`, `fix623` | `w622ReloadReordersToolsTest` (both), `w622SurvivesFix623Test` | prefix, inductive for the fix | `extensions/adapters/providers/mock/tests/issue_622_reload_reorders_tools_test.fnl` |
| #623 | `current.cacheReuseOnExtension`; prefix `current`, `fix622` | `w623MovingBreakpointMissesTest` (both), `w623SurvivesFix622Test` | prefix, inductive for the fix | `extensions/adapters/providers/anthropic/tests/issue_623_single_moving_breakpoint_test.fnl` |

Each probe is a `known-bug` test that passes while the bug reproduces against today's code:

- #617: real `/compact` with only the summary call stubbed; `usage-totals` input drops from 22100 to 100, and the summary's `:llm-end` input (30000) is in no message-derived total.
- #618: real rpc presenter, agent loop and `compact` tool on the mock provider; `turn-complete` and `result` report input 10 while the forwarded `:llm-end` events sum to 31010.
- #619: JSON presenter over one replayed exchange plus a new turn reports `total-tokens 50910` and 4 messages.
- #620: after real `/compact`, `context-token-info` still reports 44650 as `provider-reported`, while compaction's own hint and the full estimate are both under 1000.
- #621: OpenAI Chat Completions reports `total-tokens 105` and Anthropic 25 for the same 20 + 80 cached + 5 tokens; a gateway without `total_tokens` gives 0; `usage-totals` over both gives 130. `openai_responses_shared` is not probed.
- #622: tools from owners ext-a, ext-b, ext-c are sent `read,bash,grep` before and `bash,grep,read` after replaying the loader's `unregister-by-owner` plus re-register for ext-a (the two registry calls `load-module-spec!` makes, not a full on-disk reload). It lives with the mock provider because core tests may not depend on an extension provider.
- #623: real `build-body` for one and two rounds of ten parallel calls: 3 markers each, 22 and 43 message blocks, the tail breakpoint moves 21 blocks, and request 2 does not re-mark request 1's tail. The ~20-block lookback itself is Anthropic's documented behaviour and is not exercised (no network).

Mutants (`mutants.tsv`): removing the #623 re-mark, the #622 canonical order, the #620 epoch, the #621 normalization, or the summary call's ledger entry is each caught by its invariant in `fixed`; each proof model has its own mutants (including a tool_search activation not counted as a named break, and a run without a ledger marker).


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
