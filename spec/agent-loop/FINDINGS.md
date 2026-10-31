# Agent step loop

Model: [`model.qnt`](model.qnt).
Scope: one agent across 2 user steps. Covers `step` (it appends the user message, runs the loop under xpcall, and appends one `:aborted` assistant on cancel) and `step-loop` (safety cap, steering drain at the top of each turn, `:llm-start`, one provider outcome, the yield after the assistant is appended, then dispatch).
Dispatch is one of three paths: error stop; tool use, which either refuses the calls under `:tool-choice :none` or runs them; or a natural stop, which then polls steering and follow-up.
`run-tool-calls` is modelled with serial calls and consecutive parallel-safe batches, and a cancel can land at every cooperative yield: after `:llm-start`, inside the provider, after llm-end, before and after each serial tool, and mid-batch.
Steering and follow-up queues are drained one at a time while the agent is busy, and a queued line may be `""`.
The `:agent-turn-complete` status comes from `turn_lifecycle`.
Each provider call is one nondeterministic outcome; retries belong to the network domain.

Code: `packages/core/src/fen/core/agent.fnl` (`step`, `step-loop`, `run-tool-calls`, `run-serial-tool-call`, `run-parallel-tool-batch`, `append-cancelled-tool-results!`, `refuse-tool-calls!`, `inject-user-lines!`, `inject-after-natural-stop!`, `same-turn-edit-conflicts`, `context-message?`), `packages/core/src/fen/core/tools.fnl`, `extensions/behaviors/kernel/steering/service.fnl`, `packages/fen/src/fen/{interactive,turn_submit,turn_lifecycle}.fnl`, `extensions/adapters/providers/shared/streaming.fnl` (`finalize-stream-state`), `extensions/adapters/providers/anthropic/anthropic_messages.fnl`.

Main modules: `current` (every outcome), `wellFormed` (tool calls only ever arrive with `:tool-use` and parseable arguments), `lengthOnly` / `badArgsOnly` (each isolates one malformed-reply bug), and `fixed`.

## What holds

These are worth keeping as regression properties.
The model found no counterexample, and a probe swept the real loop: 100 runs (serial, parallel, mixed, and `:none`), cancelling at the k-th yield for k = 1..25, 36 of which actually cancelled.
The sweep found 0 violations of provider-valid history, of exactly one `:aborted` per cancel, and of `:tool-call` events = `:tool-result` events = result messages.

- `wellFormed.providerValidRequests`, `wellFormed.historyValidWhenIdle`: with well-formed replies, a cancel at any yield leaves every tool call answered once, in order, before the next request.
  This includes cancels after llm-end before tools, between serial tools, and mid parallel batch.
- `abortedOncePerCancel`: there is exactly one `:aborted` assistant per cancelled step, and it is filtered from the provider context.
- `eventsMatchHistory`: tool events mirror the result messages one for one, in order.
- `noneNeverExecutes`: `:tool-choice :none` never runs a tool.
- `queuedLinesDeliveredOnce`: every queued line is pending, injected once, or dropped (only if empty).
  Queues are drained synchronously with injection, so a cancel never loses a line.
- `boundedIterations`: the safety cap bounds every step.

## Bugs

### #606: A `:length` (or other non-`:tool-use`) reply that carries tool calls leaves them unanswered

Counterexample (`lengthOnly.historyValidWhenIdle`): `startStep → loopTop → lengthCall → naturalStop`.
`current.providerValidRequests` violates it after one more step, or immediately when steering is injected: `… lengthCall → inject → loopTop → tool2`.
`finalize-stream-state` upgrades only `:stop`, not `:length`, to `:tool-use` when the content has tool calls.
Anthropic's streaming reducer adds a `tool_use` block to `state.content` at `content_block_start`, so hitting `max_tokens` mid-call produces stop-reason `:length` with a tool call.
The Responses API's `:incomplete` status does the same.
`step-loop` dispatches on `stop-reason`, so this reply takes the natural-stop path: no results, and the message stays in context because `context-message?` drops only `:error` and empty `:aborted` messages.
The cancel guard after llm-end has the same `(= asst.stop-reason :tool-use)` test.
pi-mono's loop instead runs tools whenever `toolCalls.length > 0` (`packages/agent/src/agent-loop.ts:207`).

Confirmed with a probe that used a fake `fen.core.llm` and the real Anthropic reducer:

```
fake reply {:stop-reason :length :content [text, tool-call L1]}; step "one"; step "two"
B1  step1 result= partial  calls= 2  second-request valid= false  unanswered-before@3
B1  finalize-stream-state :length+tool-call -> length
anthropic stream: text block, tool_use start, partial input_json, message_delta max_tokens
B1b stop-reason= length  tool-calls= 1  anthropic wire tool_use= 1  tool_result= 0
```

The OpenAI converters patch orphans at the wire with a synthetic "missing tool output" result.
The Anthropic converter sends the bare `tool_use`, so this probably wedges every later request in the session: Anthropic should reject a `tool_use` that has no matching `tool_result` (rejection not run against the real API).

### #607: Malformed `edit` arguments crash the loop after the assistant is appended, before any result

Counterexample (`badArgsOnly.historyValidWhenIdle`): `startStep → loopTop → badArgs → crash`.
`same-turn-edit-conflicts` walks raw model arguments before schema validation: `(ipairs (or args.files []))` and `(?. f :path)`.
Arguments such as `{"files": [1]}`, `{"files": 5}`, or a non-table `arguments` raise a Lua error.
That error is not CANCEL-MARKER, so `step` re-raises it without pairing, and the TUI's `on-tick` reports `agent task: …`.
The assistant's tool call is left in history with no result.

Confirmed with a probe:

```
fake reply tool-use [edit E1 {:files [1]}]
B2 step ok= false  err= .../fen/core/agent.fnl:263: attempt to index a number value (local 't_30_')
B2 history valid= false  unanswered-at-end  n= 2
B2 next request valid= false  unanswered-before@3
```

More generally, no part of the loop restores pairing on a non-cancel unwind.
`run-tool-calls` only promises it for errors inside `execute-call` and for cancels.

### #608: An empty queued line makes the loop call the provider again on its own reply

Counterexample (`wellFormed.requestsEndOnUserSide`): `startStep → enqueue("") → enqueue → loopTop → text → inject → loopTop → …`.
`service.submit` queues `>` (or `>   `) while busy as the follow-up `""`, because `strip-follow-up-prefix` returns `""`.
At a natural stop, `inject-after-natural-stop!` returns true whenever the drained list is non-empty.
`inject-user-lines!` skips `""` and appends nothing, but the loop still continues.
The next request ends on the assistant's own final reply.
OpenAI returns an unrequested second answer.
Anthropic would read the trailing assistant message as a prefill (not run against the real API).
The same continue resets `refused-turns`, so under `:none` an empty line also grants a fresh refusal allowance (`wellFormed.refusalCountsSinceInput`: `… tool2 → refused → loopTop → text → enqueue → inject`).

Confirmed with a probe:

```
get-follow-up returns [""] once; replies: "answer", "again"
B3 provider calls= 2  follow-up-injected events= 0  last request ends with role= assistant  result= again
B3 submit '>' while busy -> queued follow-up text=[]  follow-up queue len= 1
```

### #609: A refused-twice turn and a safety-cap turn report `:agent-turn-complete` status `:ok`

Counterexample (`wellFormed.statusMatchesResult`): `startStep → loopTop → tool2 → refused → loopTop → tool2 → refusedTwice`.
`turn_lifecycle.complete-event` infers status from the last message: `:aborted` gives `:cancelled`, an assistant with `:error` gives `:error`, and anything else gives `:ok`.
The refusal error and the safety cap both end with tool-result messages, so a step that returned `"[error] …"` is reported as `:ok` to every `:agent-turn-complete` subscriber (goal, compact, plan, simplify).
The RPC presenter, the only caller that passes `:tool-choice :none` (its finalize turn), reports `stop-reason "tool-use"` for the same turn.

Confirmed with a probe:

```
:tool-choice :none, two tool-use replies
B4 refusal result= [error] model called tools while tool-choice is none  :error events= 1  last role= tool-result
B4 refusal lifecycle status= ok
```

### #610: Hitting the safety cap is silent on the bus

Counterexample (`wellFormed.errorSignalled`): it takes three loop iterations that keep continuing; the shortest found is `… refused → loopTop → text → inject → loopTop → tool2 → refused → safetyCap`.
The cap path only calls `log.warn` and returns `"[error] tool-call loop exceeded safety cap"`.
It emits no `:error` event.
The TUI never renders the step's return value, so an interactive user sees the turn just stop.
`:agent-turn-complete` says `:ok` (#609).

Confirmed with a probe (a fake provider that always returns a tool call):

```
[warn] agent: hit step safety cap (1000 turns)
B4 cap result= [error] tool-call loop exceeded safety cap  :error events= 0  lifecycle status= ok
```

## Candidate fix (modelled as `fixed`)

- #606: dispatch on content, not on the stop label.
  A non-error assistant with tool calls takes the tool path, in both dispatch and the cancel guard after llm-end (pi-mono's rule).
  An alternative is to pair such calls with synthetic `[truncated]` results instead of running them.
- #607: let `step`'s error handler pair every unanswered call of the last assistant for *any* unwind, not just CANCEL-MARKER (the close-turn core, #668).
  `fixed` models exactly that: the malformed arguments still crash the step, and the boundary closes the turn.
  Making `edit-call-paths` type-tolerant is still worth doing so the crash becomes an ordinary tool error.
- Cancel pairing: in `fixed`, the per-yield pairing at each exit is replaced by the same boundary, which pairs whatever `spec/core/turn` `openCalls` finds in the history (the batch runner still appends finished children in call order).
- #608: continue only when `inject-user-lines!` actually appended something.
  Separately, reject a blank follow-up in `service.submit`.
- #609/#610: carry the step outcome explicitly.
  `step` returns or emits a status (`ok | error | cancelled`) that `turn_lifecycle` uses instead of guessing from the last message.
  The cap path emits `:error` like the other error exits.

All invariants hold under `fixed` (`fixed.allInvariants`).

## Open questions

- Queued lines outlive a step that ends in error, cancel, refusal, or cap.
  Steering typed during a cancelled turn is injected into the *next* user turn, right after the new prompt.
  A follow-up queued during a turn that errors waits until some later turn reaches a natural stop.
  Nothing is lost or duplicated (`queuedLinesDeliveredOnce` holds), and `/cancel-all` clears both queues, so this may be intended.
  It is still a semantic choice that nobody has written down.
- `inject-user-lines!` skips only `""`.
  A whitespace-only steering line such as `"  "` becomes a user message.
  Anthropic is believed to reject whitespace-only text blocks (not run against the real API).
- A non-cancel error from `?yield!` inside `run-parallel-tool-batch` or `run-serial-tool-call` re-raises without pairing (`(error thrown)`).
  With today's `make-yield` that branch looks unreachable, but it is the same missing guard as #607.

## Core

The loop's essential contract is one rule: *every tool call in history is answered exactly once, in order, before the next request, however the step ends*.
Today that rule is enforced locally at each of about six exit points: the cancel after llm-end, the serial pre and post yields, a cancel inside a tool, the batch cancel, and refusal.
Each exit point carries its own `append-cancelled-tool-results!` call, keyed on `stop-reason`, which is why the two holes (#606, #607) are on paths that were not enumerated.
A smaller core is a single "close the turn" step at the `step` boundary: pair whatever calls the last assistant left open (cancelled, truncated, or crashed), append `:aborted` if cancelled, and emit one terminal status event that `turn_lifecycle` and presenters read directly (#609, #610).
Once that boundary owns pairing, the per-yield pairing code in the serial and parallel tool paths shrinks to "stop and unwind".
