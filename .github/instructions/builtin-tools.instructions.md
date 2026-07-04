---
applyTo: "extensions/behaviors/kernel/builtin-tools/**"
---

# Built-in tools

Built-in tools are intentionally minimal and POSIX-oriented; the omissions are deliberate.

- **`edit` is exact-byte match.**
  It does not do fuzzy matching; preserve exact-substring semantics and keep matches
  unambiguous.
- **Shell out to system tools for `grep`/`find`** rather than reimplementing them,
  and keep invocations POSIX-portable.
- **Don't expand the surface casually.**
  New tools or new options need a real justification; deliberate omissions are documented
  in `docs/tools.md` and should stay omitted unless the change updates that contract.
- Keep tool contracts (input schema, output shape, error handling) consistent with the
  existing tools and their tests.
