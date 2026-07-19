# Case study: inefficient subagent use in a three-issue implementation goal

## Context

In July 2026, one bounded autonomous goal attempted to implement GitHub issues #342, #333, and #325 concurrently.

The work produced three useful pull requests:

- #350 added flushed headless progress reporting.
- #351 added provider readiness and connectivity checks.
- #352 added a machine-readable continuable session CLI.

The implementation succeeded functionally, but the subagent strategy consumed far more execution time and model context than necessary.

This case study separates the useful engineering outcomes from the inefficient orchestration that produced them.

## What happened

The parent initially delegated all three issues to independent implementers.

Issues #342 and #325 were reasonably bounded.

Issue #333 was an umbrella-sized change spanning CLI parsing, backend capabilities, durable identity, locking, provider execution, strict transcript parsing, stdout isolation, process tests, documentation, and packaging.

The first #333 child ran for 1,200 seconds and timed out near an approximately 118k-token context estimate.

The parent then launched several fresh focused children.

Many spent their full 300-second budget rereading the same modules and tests before producing no commit.

The parent eventually implemented several findings directly, including physical cwd authorization, strict JSONL reads, duplicate-ID rejection, stdout isolation, and process-level tests.

Adversarial review found real defects, but reviews were repeated after incremental fixes instead of being reserved for final PR heads.

The last ten retained runs included four 300-second timeouts, one cancelled run, three review runs, and two focused implementation runs that completed in 57 and 166 seconds.

Across the full transcript, timed-out child budgets totaled at least 65 minutes.

Because some children ran concurrently, this number represents consumed execution budget rather than parent wall-clock latency.

## Why exact token accounting was unavailable

Fen already records useful pieces of telemetry.

A completed subagent result can include provider-reported `usage` in its run details.

Normalized `:llm-end` events can also carry usage for individual completed provider turns.

Run state records duration, provider/model routing, outcome, event count, restart count, and timeout status.

However, the available surfaces do not provide a complete usage ledger:

- `/subagents list` shows no token data.
- `/subagents show` does not render the stored `details.usage` field.
- A timed-out child often never writes its final JSON result.
- Usage from earlier `:llm-end` events is not aggregated into durable run totals.
- Only 20 runs and 50 events per run are retained.
- Retained-event truncation is not reflected in a completeness flag for usage totals.
- Transient `approx-context` status is an estimate of current context, not cumulative or billed usage.
- There is no workflow-level total grouped by model, outcome, or task.

Consequently, the session could identify obvious waste from durations and repeated work, but could not produce an authoritative provider-token or cost report.

## Root causes

### The objective bundled work of very different sizes

Parallelizing three issue numbers looked efficient, but #333 was much larger and more cross-cutting than the other two.

Issue count was a poor proxy for task size.

### Delegation prompts were too broad

The initial prompts asked children to inspect full issues, implement them, run focused and full checks, update documentation, and open pull requests.

That encouraged exhaustive repository exploration before the first edit.

### Fresh agents repeated discovery

After a timeout, new children received new contexts and reread the same architecture.

The workflow did not enforce a short discovery phase followed by continued work in one preserved run.

### There was no no-progress checkpoint

A focused child could consume five minutes without producing a diff, artifact, or final answer.

The parent noticed this only after timeout.

### Review happened too early and too often

Adversarial review was valuable and found correctness issues.

Re-reviewing full PRs after each small remediation repeated expensive context loading.

One review of a stable final head, followed by targeted local verification, would have been cheaper.

### Validation was duplicated

Children ran broad checks, the parent repeated focused and full checks, and CI ran them again.

The final process tests also made local-environment assumptions about directories, extension trust, and the presence of `git`, causing avoidable reruns.

### Parent-side tool output was too large

The parent loaded full PR bodies, large issue lists, full test logs, and CI logs into its own context.

Most of those operations needed only compact summaries or failure tails.

## What worked well

Adversarial review identified meaningful defects:

- progress stalled during streaming and reasoning-only output;
- goal startup displayed iteration zero;
- provider failures were classified by parsing prose in core;
- non-JSON provider checks discarded their result;
- Sakana and Codex authentication failures were misclassified;
- malformed JSONL could be silently extended;
- session cwd authorization trusted caller-controlled `PWD`;
- duplicate exact IDs were not rejected;
- stdout isolation was incomplete;
- durable continuation lacked subprocess coverage.

Focused Codex Terra agents also performed well once given concrete findings and exact worktrees.

Two such fixes completed in 57 and 166 seconds.

The lesson is not to avoid subagents or adversarial review.

The lesson is to delegate bounded artifacts at the right time and preserve telemetry about their cost and progress.

## A more efficient workflow

### Size before parallelizing

Classify work as small, medium, or umbrella-sized before launching children.

Run independent small issues in parallel.

Split umbrella issues into ordered slices with explicit interfaces.

For #333, a better sequence would have been:

1. exact backend create/get/list and strict read operations;
2. read-only `session new/list/show` CLI;
3. `session send` and locking;
4. process-level protocol and continuation tests.

### Scout once

Use one short read-only scout with a small token/time budget.

Persist its file map, risks, and test commands in the parent plan.

Do not ask every implementer to rediscover the same architecture.

### Require an early artifact

For implementation runs, establish a checkpoint such as:

- a diff;
- a failing focused test;
- a concrete design note naming exact files;
- or a request for steering.

If none appears within 60 to 90 seconds, steer, cancel, or take over instead of waiting for the full timeout.

### Preserve one implementation context

Continue or steer the existing run when possible.

Avoid launching a fresh child merely because the previous blocking call timed out at the orchestration layer.

### Separate focused and full validation

Children should run focused tests for their changes.

The parent should run one repository-wide check after integration.

CI remains the independent final confirmation.

### Review final heads once

Perform adversarial review after implementation and focused validation are complete.

Ask the reviewer to produce actionable findings with severity.

Address findings locally or with narrowly scoped fix agents.

Do not automatically rereview the whole PR after each fix.

### Keep parent context compact

Use structured `gh --json --jq` summaries.

Redirect full test logs to files and show only the failure tail.

Avoid loading complete issue and PR bodies when titles, changed files, and acceptance criteria are enough.

## Telemetry that would have changed the workflow

A live table with per-run duration, provider turns, input/output/cache tokens, and time-to-first-artifact would have made the waste visible much earlier.

A warning such as “three recent attempts with this task fingerprint timed out without a mutation” would have discouraged another fresh launch.

A durable total assembled from `:llm-end` usage events would have preserved partial usage even when the child timed out before writing its result document.

A workflow summary grouped by model and outcome would have answered whether expensive models were producing artifacts or merely repeating discovery.

## Suggested success measures

Future subagent workflows should be able to report:

- provider-reported tokens per run and per workflow;
- estimated versus provider-reported provenance;
- completed, failed, cancelled, and timed-out cost;
- provider turns and tool calls per run;
- time and tokens to first artifact;
- repeated-task and repeated-timeout warnings;
- usage grouped by provider, model, task, and outcome;
- whether totals are complete despite retention or event truncation.

For orchestration practice, useful targets are:

- no more than one exploratory scout per architectural area;
- no repeated fresh implementation attempt without steering or a changed plan;
- one adversarial review per stable PR head;
- focused tests in children and one full check in the parent;
- cancellation or steering when no useful artifact appears within the configured checkpoint.

## Related work

- #353 tracks durable per-run and workflow-level subagent usage telemetry.
- #270 tracks undercounting in context estimates and the use of provider-reported context.
- #154 tracks prompt-fragment size and prompt introspection.
- #321 added per-fragment `/prompt stats` introspection.

Those features explain prompt composition and current context size.

They do not replace a cumulative subagent usage ledger.
