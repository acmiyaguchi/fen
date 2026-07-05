---
name: issue-triage
description: Triage and prioritize issue/ticket backlogs. Use when the user asks to groom, prune, close out, organize, prioritize, or decide what to do next in GitHub, Forgejo/Gitea, Vikunja, Linear, or similar ticket queues.
user-invocable: true
---

# Issue Triage

Turn a ticket backlog into an actionable next-work queue: identify the active track, blockers, duplicates, close/defer candidates, and the single best next issue.

## When to use

Use this skill when the user asks about:

- triaging, grooming, pruning, or organizing issues/tickets;
- deciding what to work on next;
- closing stale or completed issues;
- assigning labels, milestones, projects, or priority;
- turning a large backlog into a short plan.

## Core rule

Prefer finishing the active strategic track over starting new surface area.
If the repository or project has an active cleanup/stabilization milestone, prioritize closing it before recommending unrelated features.

## Safety

- Read-only inventory is always safe.
- Do not mass-close, relabel, retitle, or remilestone tickets without explicit user approval.
- Before closing, inspect the ticket body and recent related PRs/commits when practical.
- If a ticket is probably done, recommend closure with the evidence link rather than closing silently.
- Treat unlabeled tickets as untriaged, not automatically low priority.

## Inventory

Collect enough context to understand the backlog shape.
For GitHub repositories, useful commands are:

```sh
gh issue list --limit 200 \
  --json number,title,state,labels,milestone,assignees,createdAt,updatedAt,url

gh pr list --limit 100 \
  --json number,title,state,isDraft,labels,milestone,updatedAt,url

gh label list --limit 200 --json name,description,color
```

Also inspect:

- repo guidance files such as `CLAUDE.md`, `README.md`, `CONTRIBUTING.md`, or project docs;
- milestone descriptions, especially if they include sequencing;
- umbrella issues and recently closed related issues;
- open PRs that may already satisfy issues.

For Forgejo/Gitea, use the available Forgejo/Gitea CLI or API to inspect issues, pull requests, labels, and milestones.
If the local `fj` CLI is available, useful commands include `fj issue search`, `fj issue view`, `fj pr search`, and `fj pr view`.
For Vikunja task queues, use the available Vikunja CLI or API to inspect projects, labels, priorities, due dates, and urgency.
If the local `vja` CLI is available, useful commands include `vja project ls`, `vja ls`, and `vja show`.

## Classification

Classify each meaningful ticket into one bucket:

- **Active now** — belongs to the current milestone or strategic track.
- **Next** — valuable after the active track closes.
- **Blocked** — cannot start until a named issue/PR/decision lands.
- **Duplicate / covered** — overlaps an umbrella, another ticket, or an open PR.
- **Needs scope** — goal is real but lacks acceptance criteria or next action.
- **Icebox / someday** — valid idea, not realistic in the next two milestones.
- **Close candidate** — already done, obsolete, duplicate, not planned, or no longer aligned.

Use explicit links for blockers and duplicates.
Example: `#234 is blocked by #32`; `#174 overlaps #105 but is the concrete implementation task`.

## Prioritization rubric

Rank work by:

1. **Unblocks other work** — dependency-breaking tasks first.
2. **Finishes active commitments** — milestone close-out beats novelty.
3. **Reduces architectural or operational drag** — cleanup that lowers future cost.
4. **Fixes reliability/data-loss/regression risks** — bugs outrank polish.
5. **Improves daily workflow** — UX/devex that the maintainer uses often.
6. **Contains scope** — prefer a small shippable slice over a broad platform bet.

Avoid recommending blocked work, speculative platform ports, or broad product bets as the immediate next task unless the user explicitly says that is the goal.

## Output shape

Be decisive and concise.
Prefer this structure:

```md
## Snapshot
- N open tickets
- active milestone/track: ...
- open PRs that affect triage: ...

## Do next
1. #123 — reason this is the next best issue

## Then
2. #124 — reason
3. #125 — reason

## Blocked
- #130 blocked by #99

## Close/defer candidates
- #140 — likely done by #141; verify then close
- #150 — icebox unless target platform becomes active

## Suggested ticket edits
- Add milestone `...` to #123
- Add label `blocked` to #130
- Close #140 with note: `...`
```

Always end with the concrete next action: the one issue to start, or the small set of ticket edits to confirm.

## Mutation workflow

If the user asks to apply triage changes:

1. Present the proposed edits first unless they already gave exact instructions.
2. Ask for confirmation before destructive or broad changes.
3. Batch safe label/milestone edits where possible.
4. Close issues with a short explanatory comment when the reason is not obvious.
5. Re-list the backlog slice afterward to verify the result.

## Repo-specific notes

Respect project-local guidance over this generic rubric.
For the `fen` repository specifically: if the `core-parsimony` milestone is still open, prioritize finishing it before widening new feature surface.
