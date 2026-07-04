---
applyTo: "packages/fen/src/fen/main.fnl"
---

# `main.fnl` — CLI-entry charter only

`main.fnl` was just shrunk back to its charter (#197) and must stay there.
It accepts only CLI-entry code:

- argument parsing and defaults,
- provider resolution,
- registration bootstrap,
- subcommand and auth-action dispatch.

Runtime orchestration does **not** belong here.
It goes in named modules — `turn_submit.fnl` and `turn_lifecycle.fnl` are the pattern.
Flag new closures, ad-hoc state tables, session/reload/queue mechanics, or
per-turn logic creeping back into this file; those have named homes elsewhere.
