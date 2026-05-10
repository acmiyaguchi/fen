# Skills

Agent Skills discovery and prompt behavior.

## Skills

`SKILL.md` files are discovered recursively from the original
fen roots plus pi/Agent Skills-compatible locations:
`${XDG_CONFIG_HOME:-~/.config}/fen/skills`, `.fen/skills`, bundled fen
skills materialized under `${XDG_DATA_HOME:-~/.local/share}/fen/skills/bundled`,
`~/.pi/agent/skills`, `~/.agents/skills`, project `.pi/skills`, ancestor
`.agents/skills`, and common Claude/Codex skill roots.
User and project skills are discovered before bundled skills, so a skill with
the same `name` shadows the bundled copy.
Set `FEN_DISABLE_BUNDLED_SKILLS=1` to skip bundled-skill materialization and
discovery.
Discovery skips dotdirs,
`node_modules`, and paths matched by `.gitignore`, `.ignore`, or `.fdignore`.
Explicit paths can be passed via `--skill <path>`; `--skills <dir>` remains a
compatibility alias.

Frontmatter is minimal YAML. `description` is required; `name` is optional
and falls back to the skill directory/file name. `disable-model-invocation:
true` skills are discovered but omitted from the system prompt. Discovered
skills are listed in an Agent Skills-style XML block with absolute paths; the
model uses the existing `read` tool to load the body on demand.

Use `/skills` to pick a discovered skill and show its detail panel, or
`/skills <name>` to jump directly to one skill.
Use `/skills list` to emit a text list of discovered skills, their scopes,
visibility, and source paths.
Use `/skills visible`, `/skills hidden`, `/skills builtin`, `/skills user`,
`/skills project`, or `/skills cli` to emit filtered lists.
The `skills` extension also exposes a `discovered-skills` introspection snapshot
for `/extensions skills` and runtime diagnostics.


