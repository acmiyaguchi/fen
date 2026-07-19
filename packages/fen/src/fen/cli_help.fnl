;; Focused CLI help for early subcommands.
;;
;; Keep this dependency-light: `fen <subcommand> --help` should render before
;; extension discovery, provider setup, native helpers, or the agent runtime are
;; loaded.

(local M {})

(local HELP
  {:goal
"Usage:
  fen goal [options] <objective>

Run the bounded autonomous goal workflow headlessly.
The objective starts at the first non-option argument; use -- before an
objective that begins with '-'.

Options:
  --max-iterations N   Iteration cap (default: 3, maximum: 20)
  --provider NAME      Provider to use (openai, anthropic, sakana, custom, ...)
  --model NAME         Model id for the selected provider
  --thinking LEVEL     off | minimal | low | medium | high | xhigh
  --thinking-budget N  Anthropic extended-thinking token budget
  --reasoning-effort E OpenAI Responses/Codex effort override
  --max-tokens N       Reply token cap (default: 16384)
  --retries N          Provider HTTP attempts for transient failures
  --tools NAMES        Comma-separated hard allowlist of agent tools
  --no-tools           Disable every agent tool
  --session-backend N  Session backend (default: jsonl)
  --continue           Resume the most recent session for the current cwd
  --no-session         Do not write a transcript to disk
  --skill PATH         Additional skill file or directory (repeatable)
  --extension PATH     Load an external extension file or directory (repeatable)
  -h, --help           Show this help and exit

Exit codes (goal contract):
  0  Done: objective completed successfully; --help also exits 0
  2  Not done: invalid usage, blocked workflow, or iteration cap reached
  1  Failure: provider, runtime, or internal error

Example:
  fen goal --max-iterations 5 --provider sakana --model fugu-ultra \"Add tests for the cache invalidation bug\"
"

   :list
"Usage:
  fen list [surface] [--json] [--provider NAME] [--extension PATH]

List discoverable live registry surfaces, or list entries on one surface.
With no surface, prints the available surfaces.

Surfaces:
  commands, tools, providers, models, presenters, session-backends,
  extensions, skills, agents

Options:
  --json            Emit stable JSON metadata for scripts
  --provider NAME   Select the provider used for provider/model discovery
  --extension PATH  Load an external extension before discovery (repeatable)
  -h, --help        Show this help and exit

Exit codes:
  0  Listed surfaces or entries; --help also exits 0
  2  Invalid usage, unknown surface, bad option, or discovery error
  1  Unexpected startup/runtime failure

Example:
  fen list tools --json
"

   :show
"Usage:
  fen show <surface> <name> [--json] [--provider NAME] [--extension PATH]

Show one live registry entry. Start with `fen list --json` when the surface
or entry name is unknown.

Surfaces:
  commands, tools, providers, models, presenters, session-backends,
  extensions, skills, agents

Options:
  --json            Emit stable JSON metadata for scripts
  --provider NAME   Select the provider used for provider/model discovery
  --extension PATH  Load an external extension before discovery (repeatable)
  -h, --help        Show this help and exit

Exit codes:
  0  Printed the requested entry; --help also exits 0
  2  Invalid usage, unknown surface, missing entry, ambiguous entry, or bad option
  1  Unexpected startup/runtime failure

Example:
  fen show tool read --json
"

   :run
"Usage:
  fen run [--lua|--fennel] <script> [args...]

Run a Lua or Fennel script with fen's embedded runtime.
Language is inferred from SCRIPT: .fnl uses Fennel, otherwise Lua.
Script args are exposed through Lua-style arg and varargs; use -- before a
script path that starts with '-'. The fen rocks tree is on the module path
when present.

Options:
  --lua       Run SCRIPT as Lua, overriding extension inference
  --fennel    Run SCRIPT as Fennel, overriding extension inference
  --fnl       Alias for --fennel
  --          Stop parsing fen run options; the next token is SCRIPT
  -h, --help  Show this help and exit

Exit codes:
  0  Script completed successfully; --help also exits 0
  2  Invalid usage, missing script, or unknown fen run option
  1  Script load/runtime failure

Example:
  fen run --fennel ./scripts/report.fnl --format json
"

   :providers
"Usage:
  fen providers [name]

Show provider setup help. With NAME, show a focused setup page for a built-in
provider or for custom/Ollama-style providers.

Names:
  openai, openai-responses, openai-codex, anthropic, sakana,
  custom, ollama, lm-studio, vllm

Options:
  name        Optional provider setup page to show
  -h, --help  Show this help and exit

Exit codes:
  0  Printed the index, a provider page, or --help
  2  Unknown provider setup page or invalid usage
  1  Unexpected runtime failure

Example:
  fen providers openai-codex
"})

(fn M.for-subcommand [name]
  (. HELP name))

(fn M.help? [arg]
  (or (= arg :--help) (= arg :-h) (= arg "--help") (= arg "-h")))

(fn M.write-subcommand-help! [name]
  (let [text (M.for-subcommand name)]
    (when text
      (io.write text)
      true)))

M
