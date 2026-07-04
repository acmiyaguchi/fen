---
applyTo: "**/*.md"
---

# Documentation

- **One sentence per line** where practical; this keeps diffs, review, and future
  trimming clean.
- **Put stable reference material in the right `docs/` page** rather than expanding
  `CLAUDE.md`, which stays short and focused on what an agent must know before editing.
  The page map: `development.md`, `architecture.md`, `extensions.md`, `providers.md`,
  `tools.md`, `sessions.md`, `scripts.md`, `skills.md`, `distribution.md`.
- Keep docs in sync with behavior changes in the same PR; flag code changes that
  leave the relevant page stale.
