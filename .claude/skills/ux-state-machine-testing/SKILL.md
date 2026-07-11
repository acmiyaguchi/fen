---
name: ux-state-machine-testing
description: Red-green test interactive fen UX as complete user event sequences, especially TUI input, completion, overlays, keyboard handling, and other stateful interactions.
user-invocable: true
---

# UX State-Machine Testing

Test interactive behavior from the user's starting state through the visible outcome, not only the helpers used along the way.

## When to use

Use this skill when adding, fixing, or reviewing:

- TUI input and keyboard behavior;
- slash-command or argument completion;
- menus, selectors, overlays, and dismiss behavior;
- multi-step interactions where the next key depends on persistent state;
- regressions described as a sequence of user actions.

Also follow the `fen-maintainer` skill for repository workflow and validation.

## Red-green workflow

1. Translate the report into a concrete event sequence before editing production code.
2. Name the test after the user-visible outcome, not an internal function.
3. Drive events through the highest deterministic in-process boundary available.
   For TUI keyboard behavior, prefer `input.handle-key` over calling mutation or completion helpers directly.
4. Assert the state after each meaningful event: buffer, cursor, active panel/menu, selection, emitted events, and submissions.
5. Run the focused test and confirm it fails for the expected reason.
6. Make the smallest production change that restores the UX invariant.
7. Re-run the focused test, nearby TUI tests, Fennel checks, and then the full suite.

## Write the UX contract first

Express the interaction as Given/When/Then or a transition table:

```text
Given /model snt has one fuzzy match
When Enter is pressed
Then the model reference is inserted exactly once and completion is closed
When Enter is pressed again
Then the command is submitted and the input is cleared
```

Include termination and repetition properties. Stateful UI bugs often appear on the next event, so test sequences such as Enter/Enter, Tab/Tab, Esc/type, and select/submit.

## Choose the right test layer

Use all applicable layers, but do not let lower-level tests replace a behavior test:

1. **Pure logic:** parsing, ranking, geometry, and splicing.
2. **Input state machine:** real synthetic events through `input.handle-key` or `input.handle-event`.
3. **Feature integration:** the real command/extension with fake external dependencies and the final state change.
4. **PTY smoke:** only when terminal decoding, timing, escape sequences, or the native binding matters.

The in-process TUI harness lives under:

```text
extensions/adapters/presenters/tui/tests/
```

Install `fen.testing.tui` stubs so tests remain deterministic and do not open a terminal.

## State-machine test pattern

Capture submissions and send the same key descriptors the runtime receives:

```fennel
(local submitted [])

(input.handle-key
  {:key tb.KEY_ENTER :ch 0 :mod 0}
  (fn [line] (table.insert submitted line))
  nil
  (fn [] false))
```

After each event, assert relevant observable state:

```fennel
(assert.are.equal expected state.input-buf)
(assert.are.equal expected-cursor state.input-cursor)
(assert.is_false (completion.active?))
(assert.are.same expected-submissions submitted)
```

Prefer a short local `press!` or `type!` helper when a test sends many events, but keep the production path visible and avoid building a second UI framework in tests.

## Required questions for interactive reviews

Trace one complete journey and ask:

- Can the interaction terminate?
- What does the unconditional end-of-event refresh do?
- Does the next identical key repeat an action unexpectedly?
- Are commit, dismiss, continue, and submit distinct in the contract?
- Does a function named `close!` leave the UI stably closed?
- Is the final user-visible outcome tested, or only candidate generation?
- Would the test fail if the selected value were inserted twice?

## Validation

Start focused:

```sh
make test TESTS=extensions/adapters/presenters/tui/tests/completion_test.fnl
fennel scripts/test/fennel-check.fnl
```

Then run nearby tests or the complete suite:

```sh
make test TESTS=extensions/adapters/presenters/tui/tests
make test
```

Record the red failure and green result in the implementation summary or PR description.
