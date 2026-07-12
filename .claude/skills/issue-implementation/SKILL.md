---
name: issue-implementation
description: Implement a Fen GitHub issue in an isolated worktree.
user-invocable: true
---

# Issue Implementation

Implement one selected issue at a time in an isolated worktree, keep the change scoped, validate it, and land it through a PR.

## When to use

Use this skill when the user asks to:

- start work on a specific issue;
- implement the next triaged issue;
- create a branch/worktree for an issue;
- turn an issue into code, tests, docs, and a PR;
- clean up issue work after merge.

If the user has not selected an issue yet, use the `issue-triage` skill first.
If the work touches fen source, docs, tests, extensions, or distribution plumbing, also follow the `fen-maintainer` skill.

## Core rule

One issue, one worktree, one scoped PR.
Do not mix unrelated cleanup, drive-by formatting, or opportunistic features into the implementation PR.
If follow-up work appears, create or recommend a follow-up issue instead of expanding scope.

## Preflight

Before creating a worktree, verify the issue is actionable and not already covered:

```sh
gh issue view <number>
gh pr list --search "<number>"
git status --short
git fetch --prune
```

Check:

- the issue is open and not blocked;
- no open PR already implements it;
- acceptance criteria are clear enough to start;
- the current checkout has no uncommitted work that would be confused with the new task;
- `main` is up to date.

If the issue is blocked or vague, stop and ask for a decision or propose a scoped first slice.

## Worktree setup

Use sibling worktrees outside the main repo checkout, not nested worktrees.
Use one branch per issue.

Recommended naming:

```text
../fen-issue-<number>-<short-slug>
issue/<number>-<short-slug>
```

Example:

```sh
git switch main
git pull --ff-only
git worktree add -b issue/189-provider-skeleton ../fen-issue-189-provider-skeleton main
cd ../fen-issue-189-provider-skeleton
```

If the branch already exists:

```sh
git worktree add ../fen-issue-189-provider-skeleton issue/189-provider-skeleton
```

After entering the worktree, re-read local guidance if needed:

```sh
sed -n '1,220p' CLAUDE.md
```

## Implementation plan

Before editing, write a short plan in the assistant todo list or PR draft:

```md
Issue: #<number>
Branch: issue/<number>-<slug>
Goal:
- ...

Acceptance:
- ...

Validation:
- `fennel scripts/test/fennel-check.fnl`
- `make test TESTS=...`
- `make test`
```

Keep the plan small and revise it as facts change.

## Fen implementation discipline

Follow the repo's maintainer rules:

- Prefer source-checkout iteration with `make dev` or `make dev-nix`, then `/reload` for `.fnl` changes.
- Do not hand-edit or check in generated `dist/` trees.
- Preserve hot reload: split persistent state from reloadable behavior, and resolve cross-module behavior at call time.
- Keep long-running work cooperative by passing `yield!` / `?yield-fn` through network, subprocess, reload/discovery, and large scans.
- Keep `main.fnl` limited to CLI-entry responsibilities.
- Prefer the events bus and existing register kinds over adding new hooks, queues, or mechanisms.
- Promote helpers to `fen.util.*` on second use rather than copying between extensions.
- If `core-parsimony` is open, do not widen core surface unless the issue explicitly requires it.

## Validation loop

Run the smallest useful check first, then broaden before PR.

Common fen checks:

```sh
fennel scripts/test/fennel-check.fnl
make test TESTS=path/to/focused_test.fnl
make test
make check
```

For architectural/module moves:

```sh
make graphs
sed -n '1,220p' docs/generated/graphs/summary.md
```

For distribution or binary confidence:

```sh
nix build .#fen --no-link
nix flake check
```

For live-provider confidence when relevant:

```sh
FEN_BIN=/path/to/fen make smoke
```

Do not run expensive checks first if a focused test or Fennel check will catch the current class of mistake.

## Commit hygiene

Make reviewable commits around coherent changes.
Good examples:

```text
test(providers): cover stream finalization
refactor(providers): extract shared streaming skeleton
fix(tui): clip status items before right-side overlap
docs(extensions): document UI helper fallback behavior
```

Before committing:

```sh
git diff --check
git diff --stat
git diff
git status --short
```

Do not commit temporary scratch files, local result symlinks, or generated `dist/` output.
Remove disposable Nix result links if present:

```sh
rm -f result result-*
```

## Self-review before PR

Before opening or updating a PR, review the diff against the same rules Copilot review will use.
Read `.github/copilot-instructions.md` and any relevant path-scoped files in `.github/instructions/*.instructions.md`; reference them instead of duplicating their full contents in this skill.

Run:

```sh
git diff --check
git diff --stat
git diff
```

Ask:

- Does this directly satisfy the issue, without unrelated cleanup or feature work?
- Can any new abstraction be deleted, made smaller, or kept local?
- Did the change preserve hot reload and avoid new core mechanisms unless required?
- Did behavior changes update the relevant docs and tests?
- Did source changes follow the path-specific Copilot instructions for providers, TUI, tools, extensions, tests, docs, or core kernel work?
- Did the diff avoid generated `dist/` output, disposable `result*` symlinks, and reference-only sibling checkouts?

For simplification, prefer this order:

1. delete code;
2. reuse an existing mechanism;
3. move a helper to `fen.util.*` only on second use;
4. add a new abstraction only when it removes real duplication or clarifies ownership.

If the diff grew beyond the issue, split follow-up work into another issue or PR.

## PR workflow

Land changes through a PR, not a direct push to `main`.

Create the PR from the worktree branch:

```sh
gh pr create --base main --head issue/<number>-<slug>
```

Use `Fixes #<number>` only when the PR fully closes the issue.
Use `Refs #<number>` for partial work or preparatory slices.

PR body template:

```md
## Summary

- ...
- ...

Fixes #<number>

## Validation

- `fennel scripts/test/fennel-check.fnl`
- `make test TESTS=...`
- `make test`
```

For large or uncertain work, open a draft PR early so the scope and approach are visible.
Keep the PR milestone/labels aligned with the issue when practical.

## Handling discoveries

If implementation reveals extra work:

- If required to satisfy the issue, add it to the plan and keep it minimal.
- If useful but not required, create/recommend a follow-up issue.
- If it changes the issue's acceptance criteria, comment on the issue or ask the user before continuing.
- If it exposes a blocker, pause and link the blocker instead of pushing through with a workaround that widens scope.

## After merge

From the main checkout:

```sh
git switch main
git pull --ff-only
git worktree remove ../fen-issue-<number>-<slug>
git branch -d issue/<number>-<slug>
git fetch --prune
```

If GitHub deleted the branch or the local branch cannot be deleted safely, inspect first, then use:

```sh
git branch -D issue/<number>-<slug>
```

Verify the issue closed automatically if the PR used `Fixes #<number>`.
If not, close it with a short comment linking the merged PR.
