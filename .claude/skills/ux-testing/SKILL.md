---
name: ux-testing
description: Design and implement tests for user-visible Fen behavior.
user-invocable: true
---

# UX Testing

Test the behavior users experience, not only the helpers used to implement it.
Use the feature's boundary and failure risks to choose the test layers.

Also follow `fen-maintainer` for repository workflow, test locations, and validation commands.

## When to use

Use this skill when adding, fixing, or reviewing user-visible behavior, including:

- TUI input, keyboard handling, completion, menus, and overlays;
- transcript, Markdown, status, panel, viewport, and cursor rendering;
- slash commands, model switching, settings, and session workflows;
- busy, cancellation, error, retry, and recovery behavior;
- extension-provided UI or commands;
- terminal input modes, paste, mouse, resize, suspend, and shutdown;
- CLI output and noninteractive workflows.

## Start with the UX contract

Before editing production code, describe:

1. **Given:** the user's starting state and relevant configuration.
2. **When:** the action or event sequence.
3. **Then:** the visible result or durable state change.
4. **And not:** duplication, stale state, overlap, premature submission, or another forbidden outcome.
5. **Next:** what happens on the next action, redraw, reload, retry, or submission.
6. **Termination/recovery:** how the interaction completes, dismisses, cancels, or recovers.

Example:

```text
Given /model snt has one fuzzy match
When Enter is pressed
Then the model reference is inserted exactly once and completion closes
When Enter is pressed again
Then the command is submitted, input clears, and the model becomes active
```

Name tests after this outcome rather than an internal helper.

## Test taxonomy

### 1. Pure unit tests

Test deterministic logic without running a complete interaction.

Use for:

- parsing and normalization;
- fuzzy matching and ranking;
- model or command resolution;
- geometry, clipping, and wrapping calculations;
- state-independent text transformations;
- isolated registry and data-shape behavior.

Strengths: fast, focused, exhaustive edge cases.
Limitation: does not prove composed UX behavior.

### 2. Component tests

Exercise one production component through its public module API with controlled dependencies.

Use for:

- a command handler with a fake runtime API;
- panel row generation;
- completion candidate collection;
- provider or session adapter behavior at its boundary;
- event ingestion into presenter state.

Assert outputs and externally meaningful state, not private implementation details.

### 3. Input state-machine tests

Send realistic synthetic key or mouse events through the production dispatcher.

Use for:

- multi-key editing;
- completion commit/dismiss/continue/submit behavior;
- menus and overlays;
- history and scrolling;
- cancellation and busy states;
- any bug that appears only after the next event.

For the TUI, prefer `input.handle-key` or `input.handle-event` over calling mutation helpers directly.
After each meaningful event, assert buffer, cursor, active menu/panel, selection, emitted events, and submissions.

Test repetition and transitions such as:

- Enter, Enter;
- Tab, Tab;
- Esc, then typing;
- select, then submit;
- cancel, then retry;
- edit, then cursor movement;
- scroll, then new content.

### 4. Render and frame tests

Paint through the production layout and presenter path using the capture-enabled termbox stub.

Use for:

- final screen composition;
- clipping and overlap;
- narrow or short terminals;
- transcript, panel, status, and input placement;
- style or marker presence;
- cursor visibility and position;
- redraw and cache invalidation.

Prefer final presented-screen assertions when the claim is about what the user sees.
Row-helper tests alone are not sufficient for composition bugs.

The in-process TUI harness is under:

```text
extensions/adapters/presenters/tui/tests/
```

Use `fen.testing.tui` and its capture mode; normal tests must not open a real terminal.

### 5. Feature integration tests

Compose the real command, extension, presenter behavior, or registry path while faking only external boundaries.

Use for outcomes such as:

- selecting `/model` changes the active provider and model;
- a completed slash command reaches command dispatch;
- session restoration affects the next submitted turn;
- provider errors reach the expected transcript or status surface;
- reload makes changed behavior observable;
- settings persist and influence the next runtime construction.

These tests catch gaps between individually correct units.
Avoid mocking the components whose composition is the feature under test.

### 6. Contract tests

Run shared expectations against multiple implementations of the same interface.

Use for:

- providers;
- presenters;
- session or auth backends;
- extension register kinds;
- tools with a common result/error contract.

Use when the important risk is inconsistent implementations rather than one user journey.

### 7. Real-PTY tests

Run through a real pseudo-terminal only when behavior depends on the terminal or native event extraction.

Use for:

- Tab versus Ctrl-I decoding;
- Esc/Alt timing;
- bracketed paste sequences;
- mouse and resize reporting;
- terminal mode restoration;
- suspend/resume;
- actual cursor or escape-sequence behavior.

Do not use PTY tests for deterministic application-state bugs that the in-process harness can cover faster and more reliably.

### 8. Smoke and end-to-end tests

Use sparingly for critical workflows that must cross process, packaging, network, or installation boundaries.

Use for:

- built single-file binary startup;
- live-provider connectivity when explicitly enabled;
- installation/update behavior;
- a minimal complete CLI or TUI journey.

Smoke tests provide confidence, not detailed diagnosis.
Keep most behavior covered below this layer.

## Choose tests from the feature

Use this guide as a minimum, then add layers for the actual risks.

| Feature or change | Primary tests | Add when needed |
|---|---|---|
| Parser, ranking, resolver, geometry | Unit | Component for public module behavior |
| Keyboard editing or completion | State machine + unit | Feature integration for final command outcome; PTY for key decoding |
| Menu, overlay, selector | State machine | Frame test for layout; integration for selected action |
| Transcript, Markdown, panel, status | Frame/render + unit | State machine for scrolling/dismissal; integration for event source |
| Slash command | Component | State machine when entered interactively; integration for durable outcome |
| Model/settings/session workflow | Feature integration | Unit for resolution/serialization; state machine for TUI entry |
| Busy/cancel/retry/error UX | State machine + integration | Frame test for visible status; smoke only for real transport behavior |
| Provider/session/auth implementation | Contract + component | Integration at registry/runtime boundary; opt-in live smoke |
| Terminal paste/mouse/resize/modes | State machine where synthetic | PTY when native decoding or escape sequences matter |
| CLI behavior | Process integration | Unit for parsing; smoke for packaged binary |
| Hot reload | Integration | State-machine or frame test when open UI state must survive |

## Red-green workflow

1. Write the UX contract and select test layers from the taxonomy.
2. Add the smallest behavior-level regression test that reproduces the report.
3. Run it and confirm it fails for the expected reason, not fixture setup.
4. Add lower-level tests only where they clarify edge cases or diagnosis.
5. Make the smallest production change that restores the invariant.
6. Re-run the red test and confirm green.
7. Add contrast tests for adjacent behavior the fix could break.
8. Run the focused file, nearest suite, Fennel check, and then broader validation.
9. Record both the red failure and green result in the implementation or PR summary.

## Protect adjacent behavior

A regression fix can pass by disabling useful behavior globally.
Add contrast tests for the nearest intentional alternative.

For example, if Enter should dismiss a completed argument, also protect that:

- Tab can continue to another argument;
- command-name selection can open argument completion;
- exact command Enter still submits;
- Esc dismisses without changing the buffer.

Prefer one focused regression test plus one or two high-risk contrast tests over a large speculative matrix.

## Assertions for UX tests

Assert positive, negative, and lifecycle outcomes.
Depending on the feature, inspect:

- final rendered screen or rows;
- input buffer and cursor;
- menu/panel active state and selected item;
- submitted lines and invocation counts;
- emitted events and their order;
- transcript/status contents;
- active provider, model, session, or settings;
- persisted files through temporary directories;
- cancellation, cleanup, and terminal restoration;
- absence of duplicate actions, stale state, overlap, or unexpected reopening.

For stateful UX, test at least one event beyond the apparent completion point.

## Test quality rules

- Prefer behavior names: `submits the completed model once`, not `calls dismiss!`.
- Use minimal realistic fixtures.
- Drive the highest deterministic production boundary available.
- Avoid sleeps when explicit events or yields can advance state.
- Fake network, subprocess, filesystem, and clock boundaries unless they are the subject of the test.
- Reset persistent TUI state and extension registries between tests.
- Keep assertions close to the event that caused the transition.
- Make failures identify the broken UX invariant.
- Do not duplicate production logic inside the test.
- Do not let helper tests substitute for the final claimed outcome.

## Fen patterns

Synthetic input event:

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

For frame tests, install the capture-enabled stub, paint through `paint.paint-frame!`, and assert with `screen-lines` or `presented-screen-lines`.
Use small local `press!` or `type!` helpers for long sequences, but keep the production event path visible.

## Review checklist

Before considering a UX change covered, ask:

- Is the user-visible contract explicit?
- Is there a test at the boundary where the behavior is experienced?
- Does the test reach the final outcome rather than stop at candidate generation or row construction?
- Can the interaction terminate, dismiss, cancel, and recover?
- What happens on the next event, redraw, reload, or retry?
- Could an action occur twice?
- Are commit, continue, dismiss, and submit distinct where needed?
- Does the fix preserve the closest intentional alternative behavior?
- Is a PTY genuinely required, or will the deterministic harness suffice?
- Would this test fail if the original user report returned?

## Validation

Start with the test that was red:

```sh
make test TESTS=path/to/focused_test.fnl
```

Then validate the nearest behavior family and syntax:

```sh
fennel scripts/test/fennel-check.fnl
make test TESTS=extensions/adapters/presenters/tui/tests
```

Finally run the broad suite appropriate to the change, following `fen-maintainer`:

```sh
make test
make check
```
