;; Focused CLI help for early subcommands.
;;
;; Keep this dependency-light: `fen <subcommand> --help` should render before
;; extension discovery, provider setup, native helpers, or the agent runtime are
;; loaded.

(local flags (require :fen.cli_flags))

(local M {})

;; Short default top-level help. Optimized for the common case: usage lines,
;; subcommand one-liners, the agent-oriented discovery pointer, ~10 commonly
;; used flags, copy-pasteable examples, and pointers to focused subcommand help
;; and `fen --help-all`. Launcher internals, slash-command minutiae, and
;; environment-variable details live in the exhaustive `fen --help-all` output.
(local TOP-LEVEL
  (.. "fen — minimal Lua/Fennel coding agent

Usage:
  fen [options]                        Start the interactive TUI
  fen --print \"your prompt\"            One-shot; print final text and exit
  fen goal [options] <objective>       Bounded autonomous goal workflow
  fen run [--lua|--fennel] <script>    Run a Lua or Fennel script
  fen eval [--lua|--fennel] <code>     Evaluate Lua or Fennel code
  fen list [surface] [--json]          List live registry surfaces/entries
  fen show <surface> <name> [--json]   Show one live registry entry
  fen providers [name]                 Show provider setup help
  fen ext build <dir>                  Build a drop-in extension
  fen update                           Update fen in place

Agent-oriented discovery:
  Start with `fen list --json`, then inspect a surface and its entries:
    fen list tools --json
    fen list models --provider NAME --json
    fen show tool read --json
  Discovery reads live extension registries without opening a session or
  contacting an LLM (except a provider's optional dynamic model catalog).

"
      (flags.render-options :top-short {:title "Common options:" :width 20})
      "\nExamples:
  # Read-only review of a diff
  fen --no-session --tools read,grep,find,ls --print \"review the diff below: ...\"

  # Bounded implementation, then run tests
  fen goal --max-iterations 10 \"implement X; run tests\"

  # Machine-readable JSON result
  FEN_JSON_OUTPUT_PATH=out.json fen --presenter json --print \"summarize README.md\"

  # Override provider and model
  fen --provider openai-codex --model gpt-5.6-sol --print \"explain this error\"

  # Resume the last session in this directory
  fen --continue

More help:
  fen <command> --help   Focused help for a subcommand
                         (goal, list, show, run, providers)
  fen --help-all         Exhaustive help: every flag, slash commands,
                         environment variables, and launcher internals
"))

;; Exhaustive top-level help. Includes every flag plus single-file-binary
;; launcher internals (--dev-path, --extension-root, FEN_DEV_PATH,
;; FEN_EXTENSION_ROOT), the full slash-command reference, and all environment
;; variables. This is the material intentionally omitted from the short help.
(local TOP-LEVEL-ALL
  (.. "fen — minimal Lua/Fennel coding agent

This is the exhaustive reference. For a short overview run `fen --help`; for a
single subcommand run `fen <command> --help`.

Usage:
  fen [options]
  fen --print \"your prompt\"
  fen goal [options] <objective>
  fen run [--lua|--fennel] <script> [args...]
  fen eval [--lua|--fennel] <code> [args...]
  fen providers [name]
  fen list [surface] [--json] [--provider NAME]
  fen show <surface> <name> [--json] [--provider NAME]
  fen ext build <dir>
  fen update

Agent-oriented discovery:
  Start with `fen list --json`, then inspect a surface and its entries:
    fen list tools --json
    fen list models --provider NAME --json
    fen show tool read --json
  Discovery reads live extension registries without opening a session or
  contacting an LLM (except a provider's optional dynamic model catalog).

"
      (flags.render-options :top-all {:width 23})
      "\nSubcommands:
  goal [OPTIONS] OBJECTIVE
                       Run the existing bounded goal companion headlessly.
                       Prints the final iteration result and exits 0 when done,
                       2 when blocked or the cap is reached, and 1 on failure.
                       Provider, model, thinking, and session options are the
                       same as an interactive run.
  run [--lua|--fennel] SCRIPT [ARG...]
                       Run a Lua or Fennel script with fen's embedded runtime.
                       .fnl scripts use Fennel; other paths use Lua unless
                       overridden. Script args are exposed through Lua-style
                       arg and varargs. The fen rocks tree is on the module
                       path when present.
  eval [--lua|--fennel] CODE [ARG...]
                       Evaluate Lua or Fennel code with fen's embedded
                       runtime. Lua is the default; pass --fennel for Fennel.
                       Code args are exposed through Lua-style arg and
                       varargs. The fen rocks tree is on the module path when
                       present.
  list [SURFACE] [--json] [--provider NAME]
                       With no surface, list the discoverable registry surfaces.
                       Surfaces: commands, tools, providers, models, presenters,
                       session-backends, extensions, skills, agents.
                       --json emits stable metadata for scripts. `models` may
                       fetch the selected provider's dynamic model catalog.
  show SURFACE NAME [--json] [--provider NAME]
                       Show one live registry entry. Start with `fen list --json`
                       when the surface or entry name is unknown.
  providers [NAME]     Show provider setup help. With NAME, show a focused
                       manpage-style setup note for openai, openai-responses,
                       openai-codex, anthropic, sakana, or custom/Ollama
                       providers.
  ext build DIR        Build a drop-in extension's rockspec into the fen
                       rocks tree (${XDG_DATA_HOME:-~/.local/share}/fen/rocks,
                       or FEN_ROCKS_TREE) using the bundled local-only
                       LuaRocks runtime.

Slash commands (interactive mode):
  /new                 Reset the current conversation and start a fresh session.
  /compact [guidance]  Summarize older context and keep recent messages.
  /handoff [guidance]  Summarize this session and seed a fresh session with it.
                       Optional guidance controls emphasis/format.
  /reload              Hot-reload core modules and source overlays.
                       Session messages are preserved. Also re-reads
                       ~/.config/fen/models.json.
  /status              Show model, provider, message count, and token usage
  /model [index|query] Show available models; switch by list index or name
  /mem                 Show runtime memory diagnostics
  /todos               Toggle the structured todo list panel
  /prompt              Show system-prompt fragments
  /prompt rendered     Show the rendered system prompt
  /prompt stats        Show per-fragment prompt sizes (bytes/~tokens)
  /expand [on|off]     Toggle collapsed vs full tool-result bodies
  /markdown [on|off]   Toggle block-level Markdown rendering of assistant text
  /animations [on|off] Toggle TUI busy spinner animation
  /thinking [level]    Show or set provider thinking effort:
                       off | minimal | low | medium | high | xhigh.
                       Use `/thinking blocks on|off` to show or hide
                       rendered thinking blocks.
  /queue               Show or clear queued steering/follow-up messages
  /cancel-all          Cancel current turn and clear queues
  /help                Show available commands

Environment:
  OPENAI_API_KEY       Required when --provider=openai or openai-responses
  ANTHROPIC_API_KEY    Required when --provider=anthropic
  SAKANA_API_KEY       Required when --provider=sakana
  FEN_LOG              debug | info | warn | error (default: info)
  FEN_TUI_MOUSE        0/off/false/no turns off TUI mouse capture so the
                       terminal's own text selection works; on by default for
                       mouse-wheel scrolling and drag-to-copy (OSC 52).
  XDG_STATE_HOME       Sessions dir (default: ~/.local/state/fen)
  XDG_CONFIG_HOME      User skills, models.json, and settings.json dir
                       (default: ~/.config/fen)
  FEN_EXTENSIONS_PATH  Colon-separated user extension discovery roots read by
                       the extension loader.
  FEN_EXTENSION_ROOT   Single-file binary only: colon-separated trusted
                       first-party flat extension overlay roots that also
                       install a flat-module searcher (equivalent to repeated
                       --extension-root)
  FEN_ROCKS_TREE       Override the fen-managed LuaRocks tree used by
                       `fen ext build`, `fen run`, `fen eval`, and extension
                       dependency loading
  FEN_DEV_PATH         Single-file binary only: colon-separated Lua
                       module roots prepended ahead of the embedded
                       archive (equivalent to repeated --dev-path)

Custom providers:
  Add Ollama, vLLM, LM Studio, or any OpenAI-compatible endpoint by writing
  ~/.config/fen/models.json. See docs or pi-mono's models.md for the
  schema. Edits are picked up via /reload (no restart required).

Settings:
  Default provider/model/thinking are read from ~/.config/fen/settings.json
  when CLI flags are omitted. The /model and /thinking commands write this
  file.
"))

(local HELP
  {:goal
(.. "Usage:
  fen goal [options] <objective>

Run the bounded autonomous goal workflow headlessly.
The objective starts at the first non-option argument; use -- before an
objective that begins with '-'.

"
      (flags.render-options :goal {:width 20})
      "\nExit codes (goal contract):
  0  Done: objective completed successfully; --help also exits 0
  2  Not done: invalid usage, blocked workflow, or iteration cap reached
  1  Failure: provider, runtime, or internal error

Example:
  fen goal --max-iterations 5 --provider sakana --model fugu-ultra \"Add tests for the cache invalidation bug\"
")

   :list
(.. "Usage:
  fen list [surface] [--json] [--provider NAME] [--extension PATH]

List discoverable live registry surfaces, or list entries on one surface.
With no surface, prints the available surfaces.

Surfaces:
  commands, tools, providers, models, presenters, session-backends,
  extensions, skills, agents

"
      (flags.render-options :list {:width 17})
      "\nExit codes:
  0  Listed surfaces or entries; --help also exits 0
  2  Invalid usage, unknown surface, bad option, or discovery error
  1  Unexpected startup/runtime failure

Example:
  fen list tools --json
")

   :show
(.. "Usage:
  fen show <surface> <name> [--json] [--provider NAME] [--extension PATH]

Show one live registry entry. Start with `fen list --json` when the surface
or entry name is unknown.

Surfaces:
  commands, tools, providers, models, presenters, session-backends,
  extensions, skills, agents

"
      (flags.render-options :show {:width 17})
      "\nExit codes:
  0  Printed the requested entry; --help also exits 0
  2  Invalid usage, unknown surface, missing entry, ambiguous entry, or bad option
  1  Unexpected startup/runtime failure

Example:
  fen show tool read --json
")

   :run
(.. "Usage:
  fen run [--lua|--fennel] <script> [args...]

Run a Lua or Fennel script with fen's embedded runtime.
Language is inferred from SCRIPT: .fnl uses Fennel, otherwise Lua.
Script args are exposed through Lua-style arg and varargs; use -- before a
script path that starts with '-'. The fen rocks tree is on the module path
when present.

"
      (flags.render-options :run {:width 11})
      "\nExit codes:
  0  Script completed successfully; --help also exits 0
  2  Invalid usage, missing script, or unknown fen run option
  1  Script load/runtime failure

Example:
  fen run --fennel ./scripts/report.fnl --format json
")

   :providers
(.. "Usage:
  fen providers [name]

Show provider setup help. With NAME, show a focused setup page for a built-in
provider or for custom/Ollama-style providers.

Names:
  openai, openai-responses, openai-codex, anthropic, sakana,
  custom, ollama, lm-studio, vllm

"
      (flags.render-options :providers {:width 10})
      "\nExit codes:
  0  Printed the index, a provider page, or --help
  2  Unknown provider setup page or invalid usage
  1  Unexpected runtime failure

Example:
  fen providers openai-codex
")})

(fn M.for-subcommand [name]
  (. HELP name))

(fn M.top-level []
  "Short default top-level help."
  TOP-LEVEL)

(fn M.top-level-all []
  "Exhaustive top-level help, including launcher internals and env-var minutiae."
  TOP-LEVEL-ALL)

(fn M.help? [arg]
  (or (= arg :--help) (= arg :-h) (= arg "--help") (= arg "-h")))

(fn M.help-all? [arg]
  (or (= arg :--help-all) (= arg "--help-all")))

(fn M.write-top-level-help! [?all?]
  "Write short (default) or exhaustive (?all? true) top-level help to stdout."
  (io.write (if ?all? TOP-LEVEL-ALL TOP-LEVEL))
  true)

(fn M.write-subcommand-help! [name]
  (let [text (M.for-subcommand name)]
    (when text
      (io.write text)
      true)))

M
