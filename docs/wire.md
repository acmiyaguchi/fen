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

The live-child lifecycle adds these events:

- `ready` — the child is initialized and waiting for input.
- `turn-started {turn}` and `turn-complete {turn, stop-reason, usage}` bracket each turn.
- `control-ack {ref, status, reason}` answers the control message whose `seq` is `ref`, with status `accepted`, `rejected`, or `applied`; `ref` is omitted only on a rejection for a line with no usable `seq`, including an out-of-order line whose `seq` was already consumed.
- `result {final-text, stop-reason, usage, context}` carries the run's answer, with `context` of `complete` or `partial`.
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
