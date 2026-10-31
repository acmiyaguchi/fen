# Core primitives

The domain models under `spec/` describe today's code, one subsystem at a time.
Their findings converge on a small core (see "The small core" in [`../README.md`](../README.md)).
This directory models that core: one directory per primitive, each with the primitive's own invariants, imported by the domains that need it.

## How a primitive is used

Each primitive has two files:

| File | Purpose |
| --- | --- |
| `<name>.qnt` | Pure definitions only (types and functions, no state), so domain models can import it: `import turn.* from "../core/turn/turn"`. |
| `model.qnt`, `checks.tsv` | The primitive's own state machine and invariants, run by `make check-spec` like any domain. |

A domain projects its own message or state type onto the primitive's types and calls it.
Its `fixed` instance then uses the primitive instead of hand-written `FIXED` branches.
Domains that share one primitive therefore share one rule.
If a domain's `fixed` instance still holds with the shared rule, that is evidence the primitive composes.
When the code change lands, the domain's `current` instance switches to the primitive as well, and the bug rows flip to `holds`.

## Primitives

| Primitive | Issue | Status | Used by |
| --- | --- | --- | --- |
| [turn](turn/turn.qnt): close-turn pairing, replay, and the step outcome | #668 | modelled | agent-loop (`fixed`: cancel and crash pairing, outcome), sessions (`fixed`: replay, provider check, doctor) |
| store: kernel lock plus compare-and-rename | #669 | planned | sessions, auth, tools |
| job: process group and output capture | #670 | planned | tools, subagents |
| tasks: one task table with turn-keyed ownership | #671 | planned | scheduler, tui-turns, serve |
| ledger: usage as a fold over one log | #672 | planned | context, presenters |
| contrib: per-owner extension contribution map | #673 | planned | extensions, context |
| runs: subagent run table and mailbox | #674 | planned | subagents, wire |
| policy: child policy derived from the parent | #675 | planned | subagents, auth, extensions |

## turn

Rule: every assistant's tool calls are answered right after it, in call order, exactly once, and no result appears without a pending call.

- `openCalls` and `closeTurn`: whatever way a step ends, pair the calls the history still has open.
  The calls are found from what was appended, not from where the code unwound.
- `replayPlan` and `replayEntries`: turn any log into a provider-valid history by inserting synthetic results for interrupted calls and dropping results that answer nothing.
- `replayRepairs`: how far a log is from its replay, which is what `session doctor` should report.
- `outcomeOf`: the one terminal status a step reports.

`model.qnt` checks the primitive against two histories.
One is built only from moves the agent makes and is cut at any point.
The other is an arbitrary log.

| Invariant | Meaning |
| --- | --- |
| `closeTurnValid`, `closeTurnIdempotent` | Closing a turn at any point gives a valid history, and closing twice is the same as closing once. |
| `replayEqualsClose` | A log cut at any point replays to exactly what close-turn gives in memory, so `--continue` and an unwinding step follow one rule. |
| `replayValid`, `replayKeepsValid`, `replayIdempotent` | Replay makes any log valid, leaves a valid log unchanged, and is idempotent. |
| `doctorCleanIffValid` | The doctor reports zero repairs exactly when the log is already valid. |

To check that the invariants are not passing vacuously, two deliberate mutations were run once by hand.
Keeping orphan results in replay, which is what the old sessions repair did, breaks `replayValid` and `doctorCleanIffValid`.
Pairing only the first open call breaks `closeTurnValid` and `replayEqualsClose`.
