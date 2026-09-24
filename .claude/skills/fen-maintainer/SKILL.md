---
name: fen-maintainer
description: Route general fen repo maintenance to the right docs and checks. Use when editing fen's Fennel source, extensions, docs, build/Nix plumbing, or tests and no narrower skill fits; for a numbered GitHub issue use issue-implementation, for user-visible TUI/CLI tests use ux-testing, for releases use release.
user-invocable: true
---

# Fen Maintainer

`CLAUDE.md` is already in context and holds the workflow, hot-reload invariants, and gotchas.
This skill adds where to look next and the checks people forget.

## Read before changing

| Change | Read |
|---|---|
| Structure, new modules, cross-extension helpers | `docs/architecture.md#design-principles` |
| Test runner flags, smoke, graphs, profiling, reload rules | `docs/development.md` |
| Extensions, manifests, register kinds, reload lists | `docs/extensions.md` |
| Built-in tools | `docs/tools.md` |
| Providers and model config | `docs/providers.md` |
| TUI behavior or layout | `docs/tui.md`, then the `ux-testing` skill for tests |
| Nix artifacts and releases | `docs/distribution.md` |
| Review rules by path | `.github/copilot-instructions.md`, `.github/instructions/*.instructions.md` |

## Validation ladder

Run the smallest useful check while iterating and the full gate once before committing:

```sh
fennel scripts/test/fennel-check.fnl
make test TESTS=path/to/focused_test.fnl
make check
```

A command killed by a timeout has not passed; rerun it or say so.

Checks people forget:

- Added, moved, or removed a module: run `make graphs` and commit the regenerated `docs/generated/graphs/` output, or `make check` fails.
- Added a first-party extension or module: update its manifest and `reload-modules` list.
- Changed a Make target: keep it usable without Nix unless its name says `nix`.
- Touched packaging or the binary path: `nix build .#fen --no-link`, then `rm -f result result-*` if you built with a link.
