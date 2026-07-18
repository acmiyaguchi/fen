# Skills

Agent Skills discovery and prompt behavior.

`SKILL.md` files are discovered recursively from fen roots and common Agent Skills-compatible locations:

- `${XDG_CONFIG_HOME:-~/.config}/fen/skills`
- `.fen/skills`
- bundled fen skills under `${XDG_DATA_HOME:-~/.local/share}/fen/skills/bundled`
- `~/.pi/agent/skills`, `~/.agents/skills`
- project `.pi/skills`, ancestor `.agents/skills`, and common Claude/Codex skill roots

User and project skills load before bundled skills, so matching `name` values shadow bundled copies.
Set `FEN_DISABLE_BUNDLED_SKILLS=1` to skip bundled-skill materialization and discovery.
Discovery skips dotdirs, `node_modules`, and paths matched by `.gitignore`, `.ignore`, or `.fdignore`.
Pass explicit skills with `--skill <path>`; `--skills <dir>` is a compatibility alias.

Frontmatter is minimal YAML.
`description` is required; `name` is optional and falls back to the file/directory name.
`disable-model-invocation: true` keeps a discovered skill out of the system prompt.
Discovered skills appear in an Agent Skills-style XML block with absolute paths; the model loads bodies on demand with `read`.

Commands:

- `/skills` — picker/detail panel.
- `/skills <name>` — jump to one skill.
- `/skills list` — text list with scopes, visibility, and paths.
- `/skills visible|hidden|builtin|user|project|cli` — filtered lists.

The `skills` extension also exposes a `discovered-skills` introspection snapshot for `/extensions skills` and diagnostics.
