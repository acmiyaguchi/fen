(var llm nil)
(var models-mod nil)
(var thinking nil)
(var settings nil)
(var provider-registry nil)
(var auth-backend-registry nil)
(var extension-loader nil)
(var log nil)
(var rocks nil)
(var script-runner nil)
(var version-mod nil)
(var diagnostics nil)
(var provider-help nil)
(var interactive nil)

(fn ensure-version! []
  (when (not version-mod)
    (set version-mod (require :fen.version)))
  version-mod)

(fn version-line []
  (let [v (ensure-version!)]
    (if (= (type v) :table)
        (if (= (type v.format) :function)
            (v.format)
            (.. "fen " (tostring (or v.version "unknown"))
                " (" (tostring (or v.source "unknown"))
                (if v.targetSystem (.. ", " (tostring v.targetSystem)) "")
                ")"))
        (.. "fen " (tostring (or v "unknown"))))))

(fn install-runtime-info! []
  (when diagnostics
    (let [v (ensure-version!)]
      (when (and (= (type v) :table) (= (type v.info) :function))
        (let [(ok? info) (pcall v.info)]
          (when ok?
            (diagnostics.set-runtime-info! info)))))))

(fn ensure-rocks! []
  (when (not rocks)
    (set rocks (require :fen.core.extensions.rocks)))
  rocks)

(fn ensure-script-runner! []
  (when (not script-runner)
    (set script-runner (require :fen.script_runner)))
  script-runner)

(fn ensure-provider-help! []
  (when (not provider-help)
    (set provider-help (require :fen.provider_help)))
  provider-help)

(fn ensure-runtime! []
  "Load runtime modules lazily so `fen --help` can run from the single-file
   prototype without loading JSON/HTTP/TUI/provider C dependencies."
  (when (not llm)
    (set llm (require :fen.core.llm))
    (set models-mod (require :fen.core.llm.models))
    (set thinking (require :fen.core.thinking))
    (set settings (require :fen.core.settings))
    (set diagnostics (require :fen.core.diagnostics))
    (install-runtime-info!)
    (set provider-registry (require :fen.core.extensions.register.provider))
    (set auth-backend-registry (require :fen.core.extensions.register.auth_backend))
    (set extension-loader (require :fen.core.extensions.loader))
    (set log (require :fen.util.log))
    ;; fen.interactive pulls in the agent, tool/command/presenter registries,
    ;; and turn/session runtime as a side effect of its top-level requires.
    (set interactive (require :fen.interactive))))

(local USAGE
"fen — minimal Lua/Fennel coding agent

Usage:
  fen [options]
  fen --print \"your prompt\"
  fen goal [options] <objective>
  fen run [--lua|--fennel] <script> [args...]
  fen eval [--lua|--fennel] <code> [args...]
  fen providers [name]
  fen ext build <dir>
  fen update

Options:
  --provider NAME      openai | openai-responses | openai-codex |
                       anthropic | sakana | <custom from models.json>
                       (default: saved setting, else openai).
                       openai-codex uses your
                       ChatGPT subscription via OAuth — run
                       `fen --login openai-codex` once first.
  --model NAME         Model id (default: saved setting when present;
                       otherwise gpt-5.4-nano for openai and
                       openai-responses, gpt-5.5 for openai-codex,
                       claude-haiku-4-5 for anthropic, fugu-ultra for
                       sakana; or the first model declared for a custom
                       provider)
  --system TEXT        System prompt
  --system-file PATH   Read the system prompt from PATH (overrides --system)
  --max-iterations N   Goal iteration cap (default: 3, maximum: 20).
                       Valid only with `fen goal`.
  --max-tokens N       Reply token cap (default: 16384). Reasoning models
                       (gpt-5*, o1, o3) charge their thinking against this
                       cap, so 1024 leaves nothing for visible output.
  --retries N          Provider HTTP attempts for transient failures
                       (default: 4; use 1 to disable)
  --thinking LEVEL    Provider-neutral thinking level: off | minimal | low |
                       medium | high | xhigh. Maps to Anthropic budgets or
                       OpenAI reasoning effort.
  --thinking-budget N  Anthropic only: enable extended thinking with N tokens
                       (exact override; wins over --thinking)
  --reasoning-effort E  OpenAI Responses / Codex: minimal | low | medium |
                       high | xhigh. Exact override; wins over --thinking.
                       Clamped per-model where the API refuses some values
                       (e.g. gpt-5.5 minimal → low).
  --print TEXT         One-shot mode; defaults to the print presenter, prints
                       final assistant text, and exits. Combine with
                       --presenter json for a machine-readable result.
  --presenter NAME     Presenter: tui | stdio | web | print | json
                       (default: tui). json writes a structured result blob
                       (final-text, messages, usage, stop-reason) to
                       FEN_JSON_OUTPUT_PATH, or stdout when unset.
  --session-backend NAME  Session backend (default: jsonl)
  --continue           Resume the most recent session for the current cwd
  --no-session         Do not write a transcript to disk
  --skill PATH         Additional skill file or directory (repeatable)
  --skills DIR         Backward-compatible alias for --skill DIR
  --extension PATH     Load an external extension file or directory
                       (repeatable; dir expects init.fnl or init.lua)
  --login PROVIDER     Run the provider's interactive login flow (e.g.
                       openai-codex) and exit
  --logout PROVIDER    Remove the provider's stored credentials and exit
  --version            Print build/source version metadata and exit
  --dev-path DIR       Single-file binary only: prepend a Lua module
                       root so .fnl/.lua in DIR shadow the embedded
                       archive (repeatable). Consumed by the launcher.
  --extension-root DIR Single-file binary only: trusted first-party flat
                       extension overlay root (repeatable); consumed by the
                       launcher.
  -h, --help           Show this help

Subcommands:
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
")

(fn model-id-present? [provider id]
  (var found? false)
  (each [_ m (ipairs (or provider.models []))]
    (let [mid (if (= (type m) :table) m.id m)]
      (when (= (tostring mid) (tostring id))
        (set found? true))))
  found?)

(fn provider-default-model [provider]
  (or provider.default-model (models-mod.first-model-id provider)))

(var resolve-provider-config nil)

(fn fallback-from-settings! [opts reason]
  "A persisted default should not brick startup. Warn once, then fall back to
   the built-in provider default. If the built-in fallback is also unusable,
   resolve-provider-config will report the normal hard error on the second pass."
  (log.warn (.. "settings: " reason "; falling back to openai"))
  (set opts.provider :openai)
  (set opts.model nil)
  (set opts.provider-from-settings? false)
  (set opts.model-from-settings? false)
  (resolve-provider-config opts))

(fn fail-provider! [opts reason cli-message exit-code]
  "A persisted default warns and falls back; an explicit CLI value is a hard
   error. Both unusable-provider paths funnel through here so the
   settings-vs-CLI branch is written once."
  (if opts.provider-from-settings?
      (fallback-from-settings! opts reason)
      (do
        (io.stderr:write (.. cli-message "\n"))
        (os.exit exit-code))))

(set resolve-provider-config
  (fn [opts]
  "Returns a record describing the provider to use for this run:
   {:name :provider-name :model :api-key :base-url :compat}.

   Provider registry names are the dispatch contract. models.json providers
   are registered after first-party providers, so a custom provider with the
   same name overrides the built-in entry. Built-ins require their configured
   auth; custom providers may have no api-key at all (Ollama-style local
   servers)."
  (let [name opts.provider
        provider (provider-registry.find name)]
    (if (not provider)
        (fail-provider!
          opts
          (.. "defaultProvider " (tostring name) " is not configured")
          (let [help (ensure-provider-help!)]
            (help.unknown-provider-message name))
          2)
        (let [default-model (provider-default-model provider)
              model (if (and opts.model opts.model-from-settings?
                             default-model
                             (> (length (or provider.models [])) 0)
                             (not (model-id-present? provider opts.model)))
                        (do (log.warn (.. "settings: defaultModel "
                                          (tostring opts.model)
                                          " is not declared for provider "
                                          (tostring name)
                                          "; using " (tostring default-model)))
                            default-model)
                        (or opts.model default-model))]
          (if provider.auth-backend
              ;; Auth-backed providers resolve credentials through the
              ;; extension auth-backend registry so providers/auth can ship
              ;; outside core.
              (let [backend (auth-backend-registry.find provider.auth-backend)]
                (if (not backend)
                    (fail-provider!
                      opts
                      (.. "defaultProvider " (tostring name)
                          " has missing auth backend "
                          (tostring provider.auth-backend))
                      (.. "missing auth backend: "
                          (tostring provider.auth-backend))
                      1)
                    (let [(ok? creds) (pcall backend.get-fresh-creds!)]
                      (if (not ok?)
                          (fail-provider!
                            opts
                            (.. "defaultProvider " (tostring name)
                                " is unavailable: " (tostring creds))
                            (tostring creds)
                            1)
                          {:name name :provider-name provider.name :api provider.api
                           :api-key nil :model model :base-url provider.base-url
                           :compat provider.compat :creds creds}))))
              (let [key-var provider.api-key-var
                    env-key (and key-var (os.getenv key-var))]
                (if (and key-var (or (not env-key) (= env-key "")))
                    (fail-provider!
                      opts
                      (.. "defaultProvider " (tostring name)
                          " requires " (tostring key-var))
                      (let [help (ensure-provider-help!)
                            ;; `fail-provider!` always falls back to the
                            ;; built-in default when the settings-derived
                            ;; provider is missing creds, so by the time this
                            ;; message renders, the active provider is either
                            ;; explicit (--provider) or the built-in fallback.
                            source (if opts.provider-explicit? :explicit :default)]
                        (help.missing-provider-message name key-var source))
                      1)
                    {:name name :provider-name provider.name :api provider.api
                     :api-key (or env-key provider.api-key)
                     :model model
                     :base-url provider.base-url
                     :compat provider.compat}))))))))

(fn parse-args [argv ?start-index ?goal-mode]
  ;; Don't pre-fill :max-tokens here — keep it nil unless the user passes
  ;; --max-tokens, so the default lives in make-agent's `(or max-tokens N)`
  ;; fallback. That way /reload picks up a changed default without a
  ;; restart.
  (let [opts {:presenter :tui
              :extra-skill-paths [] :extension-paths []
              :session-backend :jsonl}]
    (var i (or ?start-index 1))
    (var collecting-objective? false)
    (when ?goal-mode
      (set opts.goal? true)
      (set opts.presenter :goal-headless)
      (set opts.objective-parts []))
    (while (<= i (length argv))
      (let [a (. argv i)]
        (if (or (= a :-h) (= a :--help))
            (do (set opts.help? true) (set i (+ i 1)))
            (= a :--version)
            (do (set opts.version? true) (set i (+ i 1)))
            (= a :--provider)
            (do (set opts.provider (. argv (+ i 1)))
                (set opts.provider-explicit? true)
                (set i (+ i 2)))
            (= a :--model)
            (do (set opts.model (. argv (+ i 1)))
                (set opts.model-explicit? true)
                (set i (+ i 2)))
            (= a :--system)
            (do (set opts.system (. argv (+ i 1))) (set i (+ i 2)))
            (= a :--system-file)
            (let [path (. argv (+ i 1))
                  f (io.open path :r)]
              (when (not f)
                (io.stderr:write (.. "cannot read --system-file: " path "\n"))
                (os.exit 2))
              (set opts.system (f:read :*a))
              (f:close)
              (set i (+ i 2)))
            (= a :--max-iterations)
            (if ?goal-mode
                (do (set opts.max-iterations-given? true)
                    (set opts.max-iterations (tonumber (. argv (+ i 1))))
                    (set i (+ i 2)))
                (do (io.stderr:write "--max-iterations is valid only with `fen goal`\n")
                    (os.exit 2)))
            (= a :--max-tokens)
            (do (set opts.max-tokens (tonumber (. argv (+ i 1)))) (set i (+ i 2)))
            (or (= a :--retries) (= a :--retry-max-attempts))
            (do (set opts.retry-max-attempts (tonumber (. argv (+ i 1))))
                (set i (+ i 2)))
            (= a :--thinking)
            (do (set opts.thinking (. argv (+ i 1)))
                (set i (+ i 2)))
            (= a :--thinking-budget)
            (do (set opts.thinking-budget (tonumber (. argv (+ i 1))))
                (set i (+ i 2)))
            (= a :--reasoning-effort)
            (do (set opts.reasoning-effort (. argv (+ i 1)))
                (set i (+ i 2)))
            (= a :--print)
            (if ?goal-mode
                (do (io.stderr:write "--print cannot be used with `fen goal`\n")
                    (os.exit 2))
                (do (set opts.print (. argv (+ i 1)))
                    (set i (+ i 2))))
            (= a :--presenter)
            (if ?goal-mode
                (do (io.stderr:write "--presenter cannot be used with `fen goal`\n")
                    (os.exit 2))
                (do (set opts.presenter (. argv (+ i 1))) (set i (+ i 2))))
            (= a :--session-backend)
            (do (set opts.session-backend (. argv (+ i 1)))
                (set i (+ i 2)))
            (= a :--continue)
            (do (set opts.continue? true) (set i (+ i 1)))
            (= a :--no-session)
            (do (set opts.no-session? true) (set i (+ i 1)))
            (or (= a :--skill) (= a :--skills))
            (do (table.insert opts.extra-skill-paths (. argv (+ i 1)))
                (set i (+ i 2)))
            (= a :--extension)
            (do (table.insert opts.extension-paths (. argv (+ i 1)))
                (set i (+ i 2)))
            (= a :--login)
            (do (set opts.login (. argv (+ i 1))) (set i (+ i 2)))
            (= a :--logout)
            (do (set opts.logout (. argv (+ i 1))) (set i (+ i 2)))
            (and ?goal-mode (= a :--))
            (do (set collecting-objective? true) (set i (+ i 1)))
            (and ?goal-mode
                 (or collecting-objective?
                     (not= (string.sub (tostring a) 1 1) "-")))
            (do (set collecting-objective? true)
                (table.insert opts.objective-parts (tostring a))
                (set i (+ i 1)))
            (do (io.stderr:write (.. "unknown arg: " a "\n")) (os.exit 2)))))
    (when ?goal-mode
      (set opts.objective (table.concat opts.objective-parts " "))
      (set opts.objective-parts nil)
      (when (and (= opts.objective "") (not opts.help?))
        (io.stderr:write "usage: fen goal [options] <objective>\n")
        (os.exit 2))
      (when (and opts.max-iterations-given? (not opts.max-iterations))
        (io.stderr:write "--max-iterations must be an integer from 1 to 20\n")
        (os.exit 2))
      (set opts.max-iterations (or opts.max-iterations 3))
      (set opts.max-iterations-given? nil)
      (when (or (not= opts.max-iterations (math.floor opts.max-iterations))
                (< opts.max-iterations 1) (> opts.max-iterations 20))
        (io.stderr:write "--max-iterations must be an integer from 1 to 20\n")
        (os.exit 2)))
    (when (and opts.print (= opts.presenter :tui))
      ;; `--print` is a one-shot presenter selection, not an interactive
      ;; mode modifier. Default to the print presenter, but only when no
      ;; non-default presenter was requested explicitly (e.g. `--presenter
      ;; json --print TEXT` keeps json). Order-independent with `--presenter`.
      (set opts.presenter :print))
    (when opts.thinking
      (when (not thinking)
        (set thinking (require :fen.core.thinking)))
      (when (not (thinking.valid-level? opts.thinking))
        (io.stderr:write (.. "invalid --thinking: " (tostring opts.thinking)
                            " (expected " (thinking.level-list) ")\n"))
        (os.exit 2)))
    (when (and (not= opts.presenter :tui)
               (not= opts.presenter :stdio)
               (not= opts.presenter :web)
               (not= opts.presenter :print)
               (not= opts.presenter :json)
               (not= opts.presenter :goal-headless))
      (io.stderr:write (.. "unknown --presenter: " (tostring opts.presenter)
                          " (expected tui | stdio | web | print | json)\n"))
      (os.exit 2))
    (when (and (or (= opts.presenter :print) (= opts.presenter :json))
               (not opts.print))
      (io.stderr:write (.. "--presenter " (tostring opts.presenter)
                          " requires --print TEXT\n"))
      (os.exit 2))
    opts))

(fn apply-defaults [opts]
  "Apply persisted default provider/model after CLI parsing. CLI flags win;
   settings.json wins over the built-in openai fallback."
  (let [s (settings.load)]
    (if (not opts.provider)
        (if s.default-provider
            (do (set opts.provider s.default-provider)
                (set opts.provider-from-settings? true))
            (set opts.provider :openai)))
    (when (and (not opts.model)
               s.default-model
               (= (tostring opts.provider) (tostring s.default-provider)))
      (set opts.model s.default-model)
      (set opts.model-from-settings? true))
    (when (and (not opts.thinking)
               (not opts.thinking-budget)
               (not opts.reasoning-effort)
               s.default-thinking)
      (if (thinking.valid-level? s.default-thinking)
          (set opts.thinking s.default-thinking)
          (log.warn (.. "settings: defaultThinking "
                        (tostring s.default-thinking)
                        " is invalid; ignoring"))))
    opts))

(fn run-ext-subcommand [argv]
  (if (and (= (. argv 1) :ext) (= (. argv 2) :build) (. argv 3))
      (do
        (ensure-rocks!)
        (os.exit (rocks.build! (. argv 3))))
      (do
        (io.stderr:write "usage: fen ext build <dir>\n")
        (os.exit 2))))

(fn run-update-subcommand [argv]
  (let [update (require :fen.update)]
    (os.exit (update.run! argv))))

(fn run-provider-help-subcommand [argv]
  (let [help (ensure-provider-help!)
        (output code) (help.dispatch argv)]
    (io.write output)
    (os.exit code)))

(fn provider-for-auth-backend [backend-name]
  "Find the provider wired to backend-name. Prefer an exact name match so
   adoption stays deterministic if several providers share an auth backend."
  (var exact nil)
  (var any nil)
  (each [_ p (ipairs (provider-registry.list))]
    (when (= p.auth-backend backend-name)
      (when (not any) (set any p))
      (when (= p.name backend-name) (set exact p))))
  (or exact any))

(fn adopt-default-after-login! [backend-name]
  "First-boot convenience: after a successful login, if no default provider is
   persisted yet, adopt the just-authenticated provider and its default model so
   the user need not run /model manually. Best-effort — a failure here must
   never mask a successful login."
  (let [p (provider-for-auth-backend backend-name)]
    (when (and p p.default-model)
      (let [(ok? wrote?) (pcall settings.adopt-default-if-unset!
                                p.name p.default-model)]
        (if (not ok?)
            (log.warn (.. "login: could not persist default provider: "
                          (tostring wrote?)))
            wrote?
            (io.write (.. "\nDefault provider set to " (tostring p.name)
                          " (" (tostring p.default-model)
                          "). Run `fen` to start.\n")))))))

(fn run-auth-action! [opts action method-key]
  "Dispatch --login/--logout to the named provider's auth-backend.
   action is the name string the user passed; method-key is :login!
   or :logout!. Returns the exit code."
  (let [backend (auth-backend-registry.find action)]
    (when (not backend)
      (io.stderr:write (.. "unknown auth backend: " (tostring action) "\n"))
      (os.exit 2))
    (let [method (. backend method-key)]
      (when (not method)
        (io.stderr:write (.. "auth backend " (tostring action)
                             " does not support " (tostring method-key) "\n"))
        (os.exit 2))
      (let [(ok? err) (pcall method)]
        (when (not ok?)
          (io.stderr:write (.. (tostring err) "\n"))
          (os.exit 1)))
      (when (= method-key :login!)
        (adopt-default-after-login! action))
      (os.exit 0))))

(fn main [argv]
  (when (= (. argv 1) :ext)
    (run-ext-subcommand argv))
  (when (= (. argv 1) :providers)
    (run-provider-help-subcommand argv))
  (when (= (. argv 1) :update)
    (run-update-subcommand argv))
  (ensure-rocks!)
  (rocks.prepend-tree!)
  (when (or (= (. argv 1) :run) (= (. argv 1) :eval))
    (let [runner (ensure-script-runner!)]
      (os.exit (if (= (. argv 1) :eval)
                   (runner.eval! argv)
                   (runner.run! argv)))))
  (let [goal-mode? (= (. argv 1) :goal)
        parsed (parse-args argv (if goal-mode? 2 1) goal-mode?)]
    (when parsed.help? (io.write USAGE) (os.exit 0))
    (when parsed.version? (io.write (.. (version-line) "\n")) (os.exit 0))
    (ensure-runtime!)
    (let [opts (apply-defaults parsed)]
      ;; Load non-interactive extensions before provider resolution so
      ;; extension-contributed providers/auth backends are selectable at
      ;; startup. Interactive-only extensions (notably TUI) are still loaded
      ;; later by interactive.run!.
      (extension-loader.load! opts {:interactive? false})
      (models-mod.register-providers!)
      ;; --login / --logout are one-shot operations that exit before the
      ;; TUI or any session is opened. They run after extension load so
      ;; the auth-backend registry is populated.
      (when opts.login (run-auth-action! opts opts.login :login!))
      (when opts.logout (run-auth-action! opts opts.logout :logout!))
      ;; Validate config + auth eagerly so misconfiguration fails before we
      ;; spin up the TUI or open a session file. The same call runs again
      ;; inside make-agent-from-opts; resolve-provider-config is cheap and
      ;; idempotent.
      (resolve-provider-config opts)
      (let [exit-code (interactive.run! opts resolve-provider-config)]
        (when (= (type exit-code) :number)
          (os.exit exit-code))))))

(main arg)
