---
name: milestone-burndown
description: Orchestrate burning down a GitHub milestone by implementing each issue via a worker-tier subagent, adversarially reviewing it with a different provider, merging, and releasing. Use when asked to burn down, drive, or autonomously work through a milestone or issue queue in this repo.
user-invocable: true
---

# Milestone Burndown

Drive a milestone to zero open issues: pick the next issue, implement it in a
worktree via a worker-tier agent, adversarially review it cross-provider,
merge, compact, repeat, then release.

## When to use

Use this skill when the user asks to:

- burn down / drive / grind through a milestone;
- work through the backlog autonomously with review;
- run an implement-and-review loop over several issues.

For single issues use `issue-implementation` directly; for choosing what to
work on outside a milestone use `issue-triage`.

## Model tiers

Two pools, usable interchangeably within a tier (failover on rate limits or
outages) and adversarially across providers:

| Tier | Models | Roles |
|---|---|---|
| heavy | `openai-codex` / `gpt-5.6-sol`, `sakana` / `fugu-ultra` | orchestrator, escalation, review of hard or large diffs |
| worker | `openai-codex` / `gpt-5.6-terra`, `sakana` / `fugu` | implementation, routine review |

Rules:

- The orchestrator (this session) runs on a heavy model and holds only
  milestone state — issue list, per-issue status, PR numbers. Never pull file
  contents or full diffs into the orchestrator context; delegate all reading.
- The adversarial reviewer MUST use a different provider than the implementer
  (terra implements → fugu reviews; fugu implements → terra or sol reviews).
- Real redundancy is only cross-provider: sol/terra share one `openai-codex`
  credential and fugu/fugu-ultra one `SAKANA_API_KEY`, so a rate limit or
  outage hits the whole provider. On throttling, hop providers (and keep the
  cross-provider review rule by swapping both roles), don't swap models
  within a provider.
- Review model selection: worker tier (`fugu` or `terra`) for routine diffs;
  heavy tier (`fugu-ultra`, or `sol` when the implementer was on sakana) for
  large or hard diffs — fugu models are reasoning-only with a 1M context
  window, so prefer `fugu-ultra` when the diff is big.
- Escalation: after two failed worker-tier attempts on one issue, retry once
  with a heavy model. If that fails, comment findings on the issue, label it,
  and move on.

## Design principles are part of the contract

Both phases enforce the repo's design principles
(`docs/architecture.md#design-principles`) and the core-parsimony guardrails
in `CLAUDE.md`. The short form:

- one mechanism per job — reuse the events bus and existing register kinds
  before adding hooks, kinds, or queues;
- the core is the kernel only — `packages/core` gets agent loop, types,
  provider dispatch, prompt assembly, tools, loader/registry/events; nothing
  else, and `main.fnl` stays CLI-entry only;
- promote on second use — shared helpers move to `fen.util.*`, never
  copy-paste between extensions;
- strong, concise contracts; one spelling per command/API; no aliases, shims,
  or "just in case" wrappers;
- structured introspection — metadata as named record fields, not parsed text;
- preserve hot reload — state/behavior split, call-time module lookups,
  cooperative yielding, idempotent registration;
- prune dead and legacy code — a change that obsoletes code deletes it in the
  same PR when small, or files a follow-up issue; never silently carried.

The implementer applies these while writing; the adversary reviews against
them as a first-class dimension — a PR that works but violates a principle
gets FIX, not MERGE.

## Orchestration loop

Get the queue:

```sh
gh issue list --milestone "<milestone>" --state open --limit 200 \
  --json number,title,labels
```

Order it per `issue-triage` (smallest safe increment first; unblockers before
dependents). Then for each issue, run the phases below **serially** — the
subagent tool is fire-and-wait with a 4-parallel cap and no background jobs
yet, so do not fan out across issues.

Preflight once per run: reconcile leftover state from earlier runs with
`git worktree list` and `git branch --list 'issue/*'`. For each issue in the
queue that already has a worktree/branch, the first implementer call for it
must reattach (pass the worktree as `cwd` and say "work in the existing
checkout"), never recreate.

The `(subagent {...})` blocks below are the tool-call shapes the orchestrating
model emits — illustrations, not scripts to execute.

### 1. Implement (worker tier)

Delegate to the `implementer` agent (defined in `.fen/agents/`), overriding
model/provider per the tier table:

```fennel
(subagent {:agent "implementer"
           :task "Implement issue #<n>: <title>. Follow the issue-implementation skill conventions: sibling worktree ../fen-issue-<n>-<slug>, branch issue/<n>-<slug>, scoped diff, run `fennel scripts/test/fennel-check.fnl` and focused `make test TESTS=...`, then `make check`. Commit, push, and open a PR with `gh pr create --base main`. Report the PR number and validation results."
           :model "gpt-5.6-terra"
           :provider "openai-codex"
           :timeout-seconds 1800})
```

A timed-out child returns bounded partial progress — feed that tail back as
the `task` of a follow-up call ("continue from the progress below") rather
than restarting from scratch. Continue and repair calls target an existing
worktree: pass it as `cwd` and state "the worktree and branch already exist;
work in this checkout, do not create a worktree." A fresh child has no memory
of the first attempt, so never let it rerun worktree creation.

### 2. Adversarial review (different provider)

```fennel
(subagent {:agent "adversary"
           :task "PR #<pr> claims to fix issue #<n>. Try to refute it: read `gh pr diff <pr>` and the issue acceptance criteria, hunt for the failure scenario, run the focused tests yourself. Verdict must be one of MERGE / FIX (with concrete findings) / REJECT (with reasons)."
           :model "fugu"          ;; or fugu-ultra/sol for large or hard diffs
           :provider "sakana"     ;; must differ from the implementer's provider
           :timeout-seconds 900})
```

On FIX: one bounded repair round — send the findings back to an `implementer`
subagent with the existing worktree as `cwd`, then re-review only the
findings. On a second FIX or a REJECT: escalate per the tier rules or park
the issue with a comment. Parked issues keep their worktree only if a retry
is planned this run; otherwise remove it (`git worktree remove`, keep the
branch) so it doesn't collide later.

### 3. Merge

Only after the adversary says MERGE, CI is green, and Copilot review has
actually run — it is asynchronous and often lands after checks pass, and it
is the stated reason this repo requires PRs, so do not race it:

```sh
gh pr checks <pr> --watch
gh pr view <pr> --json reviews --jq '.reviews[].author.login'   # poll until Copilot appears
gh pr merge <pr> --squash --delete-branch
```

Have a worker subagent triage any Copilot comments before merging. If the
merge fails on conflicts (a previous issue's merge landed after this branch
was cut), send the implementer back to the worktree to rebase on fresh
`main` and re-run focused tests, then re-check and merge. Never push directly
to `main`. Then clean up the worktree per `issue-implementation` "After
merge".

### 4. Compact

After each merged issue, compact the orchestrator (`/compact` in fen, or
summarize state manually). Know what compaction actually does: it summarizes
older messages but keeps roughly the most recent 20k tokens verbatim and
no-ops below that threshold — context is floored, not flattened. To keep the
floor useful, end each issue by restating the milestone table (issue →
status → PR → verdict) in one message so the summary and recent window carry
it forward, and keep adversary findings out of the orchestrator by reference
(PR comment or issue comment) rather than by value. If context still exceeds
your budget after compaction, that is a stop condition.

## Release

When `gh issue list --milestone "<milestone>" --state open` is empty:

1. Confirm `main` is green (`gh run list --branch main --limit 3`).
2. Draft notes from merged PRs (quote multi-word milestone titles inside the
   search term, and set an explicit limit — `gh` defaults to 30 results):
   `gh pr list --state merged --limit 200 --search 'milestone:"<milestone>"' --json number,title`.
3. **Checkpoint:** present the drafted release (tag, notes, milestone summary)
   to the user and get confirmation before publishing — merges inside the
   loop are autonomous, but a tag/release is public and irreversible.
4. Follow the repo release flow (see `docs/distribution.md`); tag and
   `gh release create` per its conventions.
5. Close the milestone — resolve the numeric id from the title first:

   ```sh
   gh api --paginate repos/{owner}/{repo}/milestones \
     --jq '.[] | select(.title=="<milestone>") | .number'
   gh api -X PATCH repos/{owner}/{repo}/milestones/<number> -f state=closed
   ```

## Stop conditions

Stop the loop and report instead of pushing through when:

- an issue needs a scope decision only the user can make;
- two escalated attempts fail on the same issue;
- CI on `main` is broken by something outside the current issue;
- a merge conflict survives one rebase round;
- orchestrator context exceeds budget even after compaction;
- anything public and irreversible beyond merging reviewed PRs: tags,
  releases, force-pushes, or closing the milestone (see the release
  checkpoint).

Always end with a burndown table: issue → outcome (merged PR / parked /
blocked) and what remains.
