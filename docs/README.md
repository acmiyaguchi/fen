# fen documentation

`fen` is a small Fennel→Lua coding-agent CLI.
It is built as a reloadable microkernel: a tiny core (agent loop, canonical
types, provider dispatch, extension registry) with providers, the UI, session
storage, and even the built-in tools all shipped as first-party extensions.
It mirrors pi-mono's interface shapes in simplified form and targets Lua 5.4 on
ARMv7/Raspberry-Pi-class hardware.

For a project overview, install instructions, and a quick start, see the
[repository README](https://github.com/acmiyaguchi/fen#readme).

## Guides

- [Development workflow](development.md) — dev workflow, hot reload, checks, Nix result symlinks.
- [Architecture notes](architecture.md) — module map, canonical types, core API philosophy, implementation gotchas.
- [Extensions](extensions.md) — extension discovery, manifests, API surface, reload, packaging, examples.
- [Providers](providers.md) — provider interface, auth/wire differences, `models.json` custom providers.
- [Tools](tools.md) — built-in tool contracts and deliberate omissions.
- [Sessions](sessions.md) — JSONL session format and flags.
- [Scripts](scripts.md) — portable Lua/Fennel script runner.
- [Skills](skills.md) — SKILL.md discovery and prompt behavior.
- [Distribution](distribution.md) — Nix artifacts, single-file binary format, `package.searchers` precedence, dev overlays, releases.

## Generated reference

The [generated reference](reference.html) is scanned directly from source:
the core API, extension contribution sites, structured contracts, and module
dependency graphs.
It is part of the published documentation site rather than the repository.
