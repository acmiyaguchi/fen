---
name: issue-triage
description: Triage, organize, and prioritize issue or task backlogs.
user-invocable: true
---

# Issue Triage

Turn a backlog into an actionable queue: active track, blockers, duplicates, close/defer candidates, and the best next issue.

## When to use

Use for triaging/grooming issues, choosing next work, closing stale/completed tickets, assigning labels/milestones/projects, or pruning a large backlog into a short plan.

## Rules

- Prefer finishing the active strategic track over starting new surface area.
- If a cleanup/stabilization milestone is active, prioritize closing it before unrelated features.
- Read-only inventory is safe.
- Do not mass-close, relabel, retitle, or remilestone without explicit approval.
- Before closing, inspect the issue and recent related PRs/commits when practical.
- Treat unlabeled tickets as untriaged, not low priority.

## Inventory

For GitHub:

```sh
gh issue list --limit 200 \
  --json number,title,state,labels,milestone,assignees,createdAt,updatedAt,url

gh pr list --limit 100 \
  --json number,title,state,isDraft,labels,milestone,updatedAt,url

gh label list --limit 200 --json name,description,color
```

Also inspect repo guidance, milestone descriptions, umbrella issues, recently closed related issues, and open PRs that may already satisfy issues.
For Forgejo/Gitea, use `fj issue search/view` and `fj pr search/view` when available.
For Vikunja, use `vja project ls`, `vja ls`, and `vja show` when available.

## Classify

Use these buckets:

- **Active now** — current milestone or strategic track.
- **Next** — valuable after active work closes.
- **Blocked** — needs a named issue/PR/decision first.
- **Duplicate / covered** — overlaps another ticket or open PR.
- **Needs scope** — valid goal, unclear acceptance or next action.
- **Icebox / someday** — valid idea, not near-term.
- **Close candidate** — done, obsolete, duplicate, not planned, or no longer aligned.

Name blockers and duplicates explicitly, e.g. `#234 blocked by #32`.

## Prioritize

Rank by:

1. unblocks other work;
2. finishes active commitments;
3. reduces architectural/operational drag;
4. fixes reliability, data-loss, or regression risk;
5. improves daily workflow;
6. has contained scope.

Avoid recommending blocked work or broad speculative bets as the next task unless the user says that is the goal.

## Output

Be decisive and concise:

```md
## Snapshot
- N open tickets
- active milestone/track: ...
- open PRs affecting triage: ...

## Do next
1. #123 — reason

## Then
2. #124 — reason

## Blocked
- #130 blocked by #99

## Close/defer candidates
- #140 — likely done by #141; verify then close

## Suggested edits
- Add milestone `...` to #123
```

End with the concrete next action.

## Mutations

If asked to apply edits:

1. Present proposed edits first unless exact instructions were given.
2. Ask before destructive or broad changes.
3. Batch safe label/milestone edits.
4. Close issues with a short explanatory comment when needed.
5. Re-list the slice afterward to verify.

## Fen note

For `fen`, prioritize the `core-parsimony` milestone while it remains open.
