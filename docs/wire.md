# Wire protocol

The wire protocol is the JSONL message format between a parent and a live child agent.
It covers both directions: the child emits events and the parent sends control messages.
`packages/util/src/fen/util/wire.fnl` (`fen.util.wire`) is the authoritative schema; this page summarizes it and does not restate field types.
Golden examples of every message live in `packages/util/tests/fixtures/wire/`.

## Envelope

Every line is one JSON object with the envelope fields `v`, `seq`, `type`, and `run`, plus the payload fields for that type.
`v` is the protocol version; the current version is `1`.
`seq` is a positive integer, at most `MAX-SAFE-INTEGER` (2^53 - 1), that strictly increases per sender.
`run` is the run id both sides agree on.
Payload fields use Fen's kebab-case keys, and optional fields are omitted rather than sent as `null`.
A line may not exceed `MAX-LINE-BYTES`, so a bounded drain can always consume it.

## Child to parent events

The normalized display events are forwarded as-is: `agent-started`, `user`, `llm-start`, `llm-end`, `assistant-text`, `assistant-text-delta`, `assistant-thinking`, `assistant-thinking-delta`, `assistant-stream-end`, `tool-call`, `tool-result`, `steering-injected`, `follow-up-injected`, `agent-turn-complete`, `error`, and `info`.
`fen.util.wire.normalize` produces them with transport bounds applied and fields coerced to their schema types; truncated payloads carry `transport-truncated?`.
`steering-injected` and `follow-up-injected` may carry `ref`, the `seq` of the `steer` or `follow-up` control whose queued text was injected.

The live-child lifecycle adds these events:

- `ready` — the child is initialized and waiting for input.
- `turn-started {turn}` and `turn-complete {turn, stop-reason, usage}` bracket each turn.
- `control-ack {ref, status, reason}` answers the control message whose `seq` is `ref`, with status `accepted`, `rejected`, or `applied`; `ref` is omitted only on a rejection for a line with no usable `seq`, including an out-of-order line whose `seq` was already consumed.
- `result {final-text, stop-reason, usage, context, truncated?}` carries the run's answer, with `context` of `complete` or `partial`; `truncated?` marks a `final-text` cut to fit one line.
- `exit {status, error}` is the last line, with status `done`, `cancelled`, `failed`, or `timed-out`.

## Parent to child controls

- `prompt {text}` starts a turn; the initial task is the first `prompt`.
- `steer {text}` injects text at the next turn boundary.
- `follow-up {text}` queues text after the current turn.
- `finalize {note}` runs one final turn with tool execution disabled, then emits `result`.
- `cancel {}` aborts the in-flight turn or tool and exits `cancelled`.
- `close {}` exits cleanly after the current turn.

## Validation and rejection

`fen.util.wire.decode`, `encode`, and `validate` never throw on bad input.
They return the message, or `nil` plus a rejection `{code, reason, fatal?, seq, type, run, errors}`.
Rejection codes are `malformed`, `too-large`, `invalid` (bad envelope), `version-mismatch`, `unknown-type` (including a type from the other direction), `invalid-payload`, and `out-of-order` (from `receive!`).
A line without `v` is an `invalid` envelope, while a different `v` is a `version-mismatch`.
A `version-mismatch` is fatal: there are no compatibility shims, so the receiver stops the channel.
A child answers any other rejected control line with `control-ack` built by `fen.util.wire.rejection-ack`.
`fen.util.wire.sender` and `next!` stamp outgoing sequence numbers, and `receiver` and `receive!` enforce increasing incoming ones.

## Run state machine

`packages/util/src/fen/util/wire_session.fnl` (`fen.util.wire_session`) is the authoritative state table; the child presenter drives it and a parent mirrors it.
`decide` looks up a (state, control) pair, `advance` looks up an internal child event, and `terminal?` marks the exit statuses.

```
starting → ready → running ⇄ ready
running → closing → done
ready | running | closing → finalizing → done
any non-terminal → cancelled | failed | timed-out
```

| State \ control | `prompt` | `steer` | `follow-up` | `finalize` | `close` | `cancel` |
| --- | --- | --- | --- | --- | --- | --- |
| `starting` | rejected | rejected | rejected | rejected | rejected | accepted → `cancelled` |
| `ready` | accepted → `running`, starts a turn | accepted → `running`, starts a turn | accepted → `running`, starts a turn | accepted → `finalizing`, starts the tool-free turn | accepted → `done` | accepted → `cancelled` |
| `running` | rejected | accepted, steering queue | accepted, follow-up queue | accepted → `finalizing`, interrupts the turn | accepted → `closing` | accepted → `cancelled` |
| `closing` | rejected | rejected | rejected | accepted → `finalizing`, interrupts the turn | applied | accepted → `cancelled` |
| `finalizing` | rejected | rejected | rejected | applied | applied | accepted → `cancelled` |
| terminal | rejected | rejected | rejected | rejected | rejected | rejected |

Internal events move the run without a control: a turn ending returns `running` to `ready`, finishes a `closing` run, and starts the tool-free turn in `finalizing`; the end of that turn finishes the run.
A passed deadline moves any non-terminal state to `timed-out`, and a fatal error to `failed`.
In a terminal state, the child waits for an interrupted turn to unwind (or throw) and then exits with that state.

### Acks

Every control line gets exactly one `control-ack`, sent before any event the control causes.

- `accepted` — the control is legal in the current state and the child acted on it; its effect shows up in later events (`turn-started`, `steering-injected`, `follow-up-injected`, `result`, `exit`).
  A queued `steer` or `follow-up` is applied when the agent injects it; the injected event's `ref` names it.
  Queued lines not yet injected are dropped when `finalize` is accepted or the run exits, and one `info` event lists the dropped control refs.
- `applied` — the control asks for what the run is already doing (a repeated `finalize`, or `close` while closing or finalizing), so nothing changes.
- `rejected` — the control is illegal in the current state, is for another `run`, or failed validation; `reason` says why.
  Invalid lines are answered with `fen.util.wire.rejection-ack`.

A `version-mismatch` gets no ack: the child exits `failed`.

### Turns and the result

A turn is one agent step; `turn-started` and `turn-complete` bracket it, and `turn` counts from 1 per run.
`turn-complete` carries the last assistant stop reason (`aborted` for an interrupted turn) and the turn's summed usage.
`finalize` interrupts a running turn at its next cooperative yield, pairs any unexecuted tool calls with cancelled results, then runs one turn with `{:tool-choice :none}` using the `note` (or a default instruction) as the user message.
`close` in `running` lets the current turn finish.
`result` is emitted exactly once, immediately before `exit done`, from the run's last assistant message; its `usage` sums the whole run and its `context` is always `complete`, because the live child answers from its whole conversation.
A `final-text` too long for one line is cut at a UTF-8 boundary and the result carries `truncated? true`.
Runs that end `cancelled`, `failed`, or `timed-out` emit no `result`.

## Child presenter

`fen --presenter rpc` runs a live child over files: it tails the control file, appends events to the event file, and exits after its `exit` event.

| Variable | Meaning |
| --- | --- |
| `FEN_WIRE_CONTROL_PATH` | Control JSONL file the parent appends to; required, and may be created later. |
| `FEN_WIRE_EVENT_PATH` | Event JSONL file the child appends to; required. |
| `FEN_WIRE_RUN_ID` | The `run` value for both directions; defaults to `run`. |
| `FEN_WIRE_DEADLINE` | Optional Unix time in seconds; past it the run exits `timed-out`. |

The task arrives as the first `prompt`; other flags such as `--provider`, `--model`, tool policy, and session flags apply as for any presenter.
The child forwards bus events whose type is a wire display event, normalized by `fen.util.wire.normalize`, and emits the lifecycle events itself.
The exit code is 0 after `exit done` and 1 otherwise.
`--print` and `--prompt-file` are rejected with `--presenter rpc`.

The child polls on the TUI's cadence: 30 ms per tick while a turn runs, 300 ms when idle, checking only the control file's size between reads.
A control line too long for one read is rejected once and skipped to its newline.
A control file that shrinks below the consumed offset is fatal (`exit failed`).
A turn the runtime starts on its own (an idle follow-up) is reported with `turn-started` like a prompt.
`cancel`, a deadline, and `finalize` take effect at the turn's next cooperative yield, so a tool that blocks without yielding delays them; a parent should keep a kill-after-grace backstop.
