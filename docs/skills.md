# Skills

Agent Skills discovery and prompt behavior.

## Discovery

`SKILL.md` files are discovered recursively from these roots, in priority order:

1. `${XDG_CONFIG_HOME:-~/.config}/fen/skills` (user)
2. `./.fen/skills` (project)
3. `~/.pi/agent/skills`, `~/.agents/skills`, `~/.claude/skills`, `~/.codex/skills` (user)
4. `.pi/skills`, `.agents/skills`, `.claude/skills`, `.codex/skills` in the working directory and each ancestor up to the nearest VCS root (project)
5. paths passed with `--skill <path>` (`--skills <dir>` is a compatibility alias)
6. bundled fen skills, materialized under `${XDG_DATA_HOME:-~/.local/share}/fen/skills/bundled`

Skills are deduplicated by canonical path and then by `name`; the first match wins.
Because bundled skills scan last, any user, project, or `--skill` copy with the same `name` shadows the bundled one.
Set `FEN_DISABLE_BUNDLED_SKILLS=1` to skip bundled-skill materialization and discovery.

Discovery stops descending at a directory that contains `SKILL.md`.
It skips dotdirs, `node_modules`, and paths matched by `.gitignore`, `.ignore`, or `.fdignore`.
`.pi/skills` also accepts direct `*.md` skill files; the other roots require `<name>/SKILL.md` directories.

## Frontmatter

Frontmatter is minimal YAML.
`description` is required; `name` is optional and falls back to the directory (or file) name.
`disable-model-invocation: true` keeps a discovered skill out of the prompt catalogue and the `skill` tool.
Other keys, such as Claude Code's `user-invocable`, are ignored.

The description is the only text the model sees before choosing a skill, so say what the skill does and when to use it.

## Prompt and loading

The system prompt carries a compact catalogue of visible skills: one `- name: description` line each, without paths.
The model loads a skill's full instructions with the `skill` tool (`{name: "<skill>"}`), which it activates through `tool_search`.
The tool result includes the skill's directory so relative references inside the skill resolve with `read`.

## Commands

- `/skills` — picker/detail panel.
- `/skills <name>` — jump to one skill.
- `/skills list` — text list with scopes, visibility, and paths.
- `/skills visible|hidden|builtin|user|project|cli` — filtered lists.

The `skills` extension also exposes a `discovered-skills` introspection snapshot for `/extensions skills` and diagnostics.
