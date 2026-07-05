# fen documentation

`fen` is a small Fennel→Lua coding-agent CLI.
It is built as a reloadable microkernel: a tiny core (agent loop, canonical
types, provider dispatch, extension registry) with providers, the UI, session
storage, and even the built-in tools all shipped as first-party extensions.
It mirrors pi-mono's interface shapes in simplified form and targets Lua 5.4 on
ARMv7/Raspberry-Pi-class hardware.

For a project overview, install instructions, and a quick start, see the
[repository README](https://github.com/acmiyaguchi/fen#readme).

DEMO_PLAYER_EMBED

## Which doc should I read?

These guides are the primary, hand-written docs; each one has a single main
audience. Read these first — the generated reference below is for lookup, not
onboarding.

| If you are… | Start with |
| --- | --- |
| running fen | the [repository README](https://github.com/acmiyaguchi/fen#readme) |
| understanding the TUI design | [TUI design guide](tui.md) |
| contributing code | [Development workflow](development.md) |
| understanding the internals | [Architecture notes](architecture.md) |
| writing an extension | [Extensions](extensions.md) |
| configuring a provider | [Providers](providers.md) |

## Guides

- [Development workflow](development.md) — dev workflow, hot reload, checks, Nix result symlinks.
- [TUI design guide](tui.md) — terminal UI spatial model, affordances, extension surfaces, recovery, and testing direction.
- [Architecture notes](architecture.md) — module map, canonical types, reloadable microkernel, design principles.
- [Extensions](extensions.md) — extension discovery, manifests, API surface, reload, packaging, examples.
- [Providers](providers.md) — provider interface, auth/wire differences, `models.json` custom providers.
- [Tools](tools.md) — built-in tool contracts and deliberate omissions.
- [Sessions](sessions.md) — JSONL session format and flags.
- [Scripts](scripts.md) — portable Lua/Fennel script runner.
- [Skills](skills.md) — SKILL.md discovery and prompt behavior.
- [Distribution](distribution.md) — Nix artifacts, single-file binary format, `package.searchers` precedence, dev overlays, releases.

## Generated reference

The generated site is reference material scanned directly from source — reach for
it to look up a specific contract, not to get oriented. It includes
[contracts](contracts.html), [API](api.html), [registries](registries.html), and
[graphs](graphs.html) pages.
Use the [sitemap](sitemap.html) for a dense index of every page and the
machine-readable artifacts.
It is part of the published documentation site rather than the repository.
