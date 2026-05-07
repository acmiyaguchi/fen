# Skills

Agent Skills discovery and prompt behavior.

## Skills

`SKILL.md` files are discovered recursively from the original
fen roots plus pi/Agent Skills-compatible locations:
`${XDG_CONFIG_HOME:-~/.config}/fen/skills`, `.fen/skills`,
`~/.pi/agent/skills`, `~/.agents/skills`, project `.pi/skills`, ancestor
`.agents/skills`, and common Claude/Codex skill roots. Discovery skips dotdirs,
`node_modules`, and paths matched by `.gitignore`, `.ignore`, or `.fdignore`.
Explicit paths can be passed via `--skill <path>`; `--skills <dir>` remains a
compatibility alias.

Frontmatter is minimal YAML. `description` is required; `name` is optional
and falls back to the skill directory/file name. `disable-model-invocation:
true` skills are discovered but omitted from the system prompt. Discovered
skills are listed in an Agent Skills-style XML block with absolute paths; the
model uses the existing `read` tool to load the body on demand.


