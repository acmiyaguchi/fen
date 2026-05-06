---
name: fen-maintainer
description: Maintain the fen Fennel coding-agent repo: edit/reload workflow, tests, non-Nix/Nix dev commands, extension discovery, and release/build checks.
user-invocable: true
---

# Fen Maintainer

Use this for maintainer work in the `fen` repo: changing Fennel source, launcher/dev workflows, docs, tests, extensions, or distribution plumbing.

## Core workflow

- Prefer source-checkout development through the single-file runtime:
  ```sh
  make dev        # uses FEN_BIN or fen on PATH
  make dev-nix    # builds .#fen, then runs bin/fen-dev
  ```
- `bin/fen-dev` sets:
  - `FEN_DEV_PATH` for `packages/{core,util,fen}/src`
  - `FEN_EXTENSION_ROOT` for `extensions/`
- After editing `.fnl` during an interactive run, use `/reload`; do not rebuild generated Lua just to test source edits.

## Checks

Run the smallest useful check first:

```sh
fennel scripts/fennel-check.fnl
make test TESTS=path/to/test.fnl
make test
```

Use Nix for reproducible/binary/distribution validation:

```sh
nix build .#fen
nix flake check
```

For live-provider smoke tests on any machine with a runnable binary:

```sh
FEN_BIN=/path/to/fen make smoke
```

## Rules

- Do not hand-edit or check in generated `dist/` trees.
- Keep Make targets usable without Nix unless the target name says `nix`.
- Keep `nix build .#fen` as the canonical production binary path.
- Project extensions live in `.fen/extensions`; user-global extensions live in `${XDG_CONFIG_HOME:-~/.config}/fen/extensions`.
- When adding first-party extensions, update the embedded manifest registry and reload/module lists as needed.
- Preserve hot-reload behavior: split persistent state from reloadable behavior and avoid capturing old function references in long-lived state.
