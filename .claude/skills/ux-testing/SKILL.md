---
name: ux-testing
description: Design and implement tests for user-visible Fen behavior.
user-invocable: true
---

# UX Testing

Test the behavior users experience, not only implementation helpers.
Use this for TUI input/rendering, slash commands, model/session/settings flows, extension UI, CLI output, busy/cancel/error behavior, and terminal input modes.
Also follow `fen-maintainer` for repo workflow and validation.

## Start with the contract

Before editing, state the behavior in user terms:

1. Given: starting state and relevant config.
2. When: action or event sequence.
3. Then: visible result or durable state change.
4. And not: duplication, stale state, overlap, premature submit, or another forbidden outcome.
5. Next: what happens on the next action/redraw/reload/retry.
6. Recovery: how it completes, dismisses, cancels, or recovers.

Name tests after this outcome, not an internal helper.

## Pick the right layer

- **Unit:** parsing, ranking, resolution, geometry, wrapping, text transforms, registry shapes.
- **Component:** one public module API with controlled dependencies, such as a command handler or panel rows.
- **Input state machine:** realistic key/mouse events through `input.handle-key` or `input.handle-event`.
- **Render/frame:** paint through the production layout with the capture-enabled termbox stub.
- **Feature integration:** real command/extension/presenter/registry composition while faking only external boundaries.
- **Contract:** shared expectations across providers, presenters, tools, sessions, auth, or register kinds.
- **Real PTY:** only terminal-native behavior such as Tab/Ctrl-I, Esc timing, paste, mouse, resize, suspend, or mode restoration.
- **Smoke/E2E:** sparingly for binary startup, live-provider connectivity, install/update, or a minimal full journey.

Guide:

| Change | Primary tests | Add when needed |
|---|---|---|
| Parser/ranking/resolver/geometry | Unit | Component |
| Keyboard editing/completion | State machine + unit | Integration; PTY for native key decoding |
| Menu/overlay/selector | State machine | Frame; integration for selected action |
| Transcript/Markdown/panel/status | Frame + unit | State machine; integration for event source |
| Slash command | Component | State machine; integration for durable outcome |
| Model/settings/session | Integration | Unit for serialization; state machine for TUI entry |
| Busy/cancel/retry/error | State machine + integration | Frame; smoke only for real transport |
| Provider/session/auth | Contract + component | Registry/runtime integration |
| Terminal modes/paste/mouse/resize | State machine where synthetic | PTY |
| CLI | Process integration | Unit for parsing; packaged smoke |
| Hot reload | Integration | State-machine/frame when UI state must survive |

## Red-green loop

1. Write the UX contract and choose layers.
2. Add the smallest behavior-level regression test.
3. Confirm it fails for the expected reason.
4. Add lower-level tests only for edge cases or diagnosis.
5. Make the smallest production fix.
6. Confirm the red test turns green.
7. Add one or two contrast tests for nearby intended behavior.
8. Run focused, nearest-suite, Fennel, then broader checks.
9. Record red failure and green result in the PR summary.

## Assertions

Assert the externally meaningful outcome and at least one lifecycle step beyond completion when stateful.
Depending on the feature, inspect rendered rows, input buffer/cursor, menu/panel state, submitted lines, emitted events, transcript/status, active provider/model/session/settings, persisted files, cleanup, and absence of duplicates or stale state.

Prefer one focused regression plus high-risk contrast tests over a speculative matrix.
A fix that passes by disabling adjacent useful behavior is not covered.

## TUI harness

Use the in-process harness under:

```text
extensions/adapters/presenters/tui/tests/
```

Use `fen.testing.tui`; normal tests must not open a real terminal.
For frame tests, install the capture-enabled stub, render via `paint.paint-frame!`, and assert with `screen-lines` or `presented-screen-lines`.

Example input path:

```fennel
(local submitted [])
(input.handle-key
  {:key tb.KEY_ENTER :ch 0 :mod 0}
  (fn [line] (table.insert submitted line))
  nil
  (fn [] false))

(assert.are.equal expected state.input-buf)
(assert.is-false (completion.active?))
(assert.are.same expected-submissions submitted)
```

Small local `press!` / `type!` helpers are fine, but keep the production event path visible.

## Test quality

- Prefer behavior names: `submits the completed model once`, not `calls dismiss!`.
- Use minimal realistic fixtures.
- Drive the highest deterministic production boundary available.
- Avoid sleeps; use explicit events or yields.
- Fake network, subprocess, filesystem, and clock boundaries unless they are the subject.
- Reset persistent TUI state and extension registries between tests.
- Keep assertions close to the transition.
- Make failures identify the broken UX invariant.
- Do not duplicate production logic in tests.
- Do not let helper tests substitute for the claimed user outcome.

Avoid broad integration assertions that count every tool, extension, prompt fragment, status item, or panel unless inventory is the contract.
Prefer positive membership checks for the behavior under test and one canonical inventory guard at most.
If adding a first-party tool/extension forces many unrelated test updates, narrow or delete the coupled assertions instead.

## Review checklist

- Is the user-visible contract explicit?
- Is there a test where the behavior is experienced?
- Does the test reach the final outcome?
- Are terminate/dismiss/cancel/recover paths covered when relevant?
- What happens on the next event, redraw, reload, or retry?
- Could an action occur twice?
- Are commit, continue, dismiss, and submit distinct where needed?
- Does the fix preserve the closest intended alternative?
- Is PTY truly required?
- Would the test fail if the original report returned?

## Validation

```sh
make test TESTS=path/to/focused_test.fnl
fennel scripts/test/fennel-check.fnl
make test TESTS=extensions/adapters/presenters/tui/tests
make test
make check
```
