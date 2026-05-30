(var agent-mod nil)
(var system-prompt nil)
(var llm nil)
(var models-mod nil)
(var thinking nil)
(var settings nil)
(var events nil)
(var register-registry nil)
(var tool-registry nil)
(var command-registry nil)
(var presenter-registry nil)
(var provider-registry nil)
(var auth-backend-registry nil)
(var session-backend-registry nil)
(var extension-loader nil)
(var checksum nil)
(var json nil)
(var log nil)
(var rocks nil)
(var script-runner nil)
(var version-mod nil)
(var diagnostics nil)
(var turn-lifecycle nil)
(var provider-help nil)

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
  (when (not agent-mod)
    (set agent-mod (require :fen.core.agent))
    (set system-prompt (require :fen.core.prompt))
    (set llm (require :fen.core.llm))
    (set models-mod (require :fen.core.llm.models))
    (set thinking (require :fen.core.thinking))
    (set settings (require :fen.core.settings))
    (set events (require :fen.core.extensions.events))
    (set diagnostics (require :fen.core.diagnostics))
    (install-runtime-info!)
    (set register-registry (require :fen.core.extensions.register))
    (set tool-registry (require :fen.core.extensions.register.tool))
    (set command-registry (require :fen.core.extensions.register.command))
    (set presenter-registry (require :fen.core.extensions.register.presenter))
    (set provider-registry (require :fen.core.extensions.register.provider))
    (set auth-backend-registry (require :fen.core.extensions.register.auth_backend))
    (set session-backend-registry (require :fen.core.extensions.register.session_backend))
    (set extension-loader (require :fen.core.extensions.loader))
    (set checksum (require :fen.util.checksum))
    (set json (require :fen.util.json))
    (set log (require :fen.util.log))
    (set turn-lifecycle (require :fen.turn_lifecycle))))

(local USAGE
"fen — minimal Lua/Fennel coding agent

Usage:
  fen [options]
  fen --print \"your prompt\"
  fen run [--lua|--fennel] <script> [args...]
  fen eval [--lua|--fennel] <code> [args...]
  fen providers [name]
  fen ext build <dir>
  fen update

Options:
  --provider NAME      openai | openai-responses | openai-codex |
                       anthropic | <custom from models.json>
                       (default: saved setting, else openai).
                       openai-codex uses your
                       ChatGPT subscription via OAuth — run
                       `fen --login openai-codex` once first.
  --model NAME         Model id (default: saved setting when present;
                       otherwise gpt-5.4-nano for openai and
                       openai-responses, gpt-5.5 for openai-codex,
                       claude-haiku-4-5 for anthropic; or the first
                       model declared for a custom provider)
  --system TEXT        System prompt
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
  --print TEXT         One-shot mode; selects the print presenter, prints
                       final assistant text, and exits
  --presenter NAME     Presenter: tui | stdio | web | print (default: tui)
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
                       openai-codex, anthropic, or custom/Ollama providers.
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
  FEN_LOG              debug | info | warn | error (default: info)
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

(fn parse-args [argv]
  ;; Don't pre-fill :max-tokens here — keep it nil unless the user passes
  ;; --max-tokens, so the default lives in make-agent's `(or max-tokens N)`
  ;; fallback. That way /reload picks up a changed default without a
  ;; restart.
  (let [opts {:presenter :tui
              :extra-skill-paths [] :extension-paths []
              :session-backend :jsonl}]
    (var i 1)
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
            (do (set opts.print (. argv (+ i 1)))
                (set opts.presenter :print)
                (set i (+ i 2)))
            (= a :--presenter)
            (do (set opts.presenter (. argv (+ i 1))) (set i (+ i 2)))
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
            (do (io.stderr:write (.. "unknown arg: " a "\n")) (os.exit 2)))))
    (when opts.print
      ;; `--print` is a one-shot presenter selection, not an interactive
      ;; mode modifier. Keep it order-independent with `--presenter`.
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
               (not= opts.presenter :print))
      (io.stderr:write (.. "unknown --presenter: " (tostring opts.presenter)
                          " (expected tui | stdio | web | print)\n"))
      (os.exit 2))
    (when (and (= opts.presenter :print) (not opts.print))
      (io.stderr:write "--presenter print requires --print TEXT\n")
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

(fn build-system-prompt [opts agent-tools]
  (system-prompt.build opts
                       (or agent-tools
                           (tool-registry.merged []))))

(fn thinking-status [provider-options]
  "Compact status-bar label for the materialized thinking/reasoning option."
  (if (?. provider-options :reasoning-effort)
      (.. "reason:" (tostring provider-options.reasoning-effort))
      (and (?. provider-options :thinking-budget)
           (> (or provider-options.thinking-budget 0) 0))
      (.. "think:" (tostring provider-options.thinking-budget))
      false))

(fn make-agent-from-opts [opts on-event extra]
  "Resolve the provider config (re-reads models.json each call so /reload
   picks up edits), then construct an Agent. The api-key, base-url, and
   compat fields ride through `:provider-options` into the provider's
   `complete`. Optional `extra` fields are forwarded to make-agent (used by
   interactive queue callbacks)."
  (let [cfg (resolve-provider-config opts)
        provider-options (thinking.level->provider-options opts.thinking cfg.api)]
    (when cfg.base-url (set provider-options.base-url cfg.base-url))
    (when cfg.compat (set provider-options.compat cfg.compat))
    (when cfg.creds (set provider-options.creds cfg.creds))
    (when opts.thinking-budget
      (set provider-options.thinking-budget opts.thinking-budget))
    (when opts.reasoning-effort
      (set provider-options.reasoning-effort opts.reasoning-effort))
    (when opts.retry-max-attempts
      (set provider-options.retry-max-attempts opts.retry-max-attempts))
    (let [agent-tools (tool-registry.merged [])
          spec {:provider-name cfg.provider-name
                :model cfg.model
                :system (build-system-prompt opts agent-tools)
                :api-key cfg.api-key
                :max-tokens opts.max-tokens
                :tools agent-tools
                : provider-options
                :thinking-status (thinking-status provider-options)
                : on-event}]
      (each [k v (pairs (or extra {}))]
        (tset spec k v))
      (agent-mod.make-agent spec))))

(fn cwd []
  ;; PWD is what the user thinks of as cwd (preserves symlinks); fall back to
  ;; pwd shell builtin if not set. We slug this for the session dir, so it
  ;; just needs to be stable per-project.
  (or (os.getenv :PWD)
      (let [pipe (io.popen "pwd")
            out (and pipe (pipe:read :*l))]
        (when pipe (pipe:close))
        (or out "/"))))

(fn resolve-session-backend [opts]
  "Return the selected backend. --no-session disables writes, but still keeps
   the backend available for --continue replay/discovery."
  (let [name (or opts.session-backend :jsonl)
        backend (session-backend-registry.find name)]
    (when (not backend)
      (io.stderr:write (.. "unknown --session-backend: " (tostring name) "\n"))
      (os.exit 2))
    (session-backend-registry.set-active! name)
    (when opts.no-session?
      (session-backend-registry.set-info! nil))
    backend))

(fn backend-info [backend session]
  (when session
    (if (and backend (= (type backend.info) :function))
        (backend.info session)
        {:backend (?. backend :name)
         :id session.id
         :path session.path
         :cwd session.cwd})))

(fn close-session [backend session]
  (when (and backend session)
    (backend.close session))
  (session-backend-registry.set-info! nil))

(fn open-session [opts backend]
  "Open a transcript handle for this run, unless sessions are disabled."
  (when (and backend (not opts.no-session?))
    (let [s (backend.open (cwd))]
      (session-backend-registry.set-info! (backend-info backend s))
      s)))

(fn start-session [opts agent backend]
  "Open the active transcript and optionally replay --continue into the agent.
   Returns (session, replayed-count). --continue appends to the existing file
   instead of opening a new transcript."
  (if (not backend)
      (values nil 0)
      opts.continue?
      (let [p (backend.latest (cwd))]
        (if (not p)
            (do (log.warn "session: --continue but no prior session found")
                (values (open-session opts backend) 0))
            (let [msgs (backend.load p)
                  s (if opts.no-session? nil (backend.open-existing p))]
              (each [_ m (ipairs msgs)]
                (table.insert agent.messages m))
              (session-backend-registry.set-info! (backend-info backend s))
              (values s (length msgs)))))
      (values (open-session opts backend) 0)))

(fn assistant-present? [messages]
  (var found? false)
  (each [_ m (ipairs messages)]
    (when (= m.role :assistant)
      (set found? true)))
  found?)

(fn make-flush [backend agent session initial-last-saved]
  "Returns a closure that appends any messages added since the last call.
   Tracks `last-saved` across invocations. Like pi-mono, holds early user-only
   messages in memory until the first assistant (including :aborted) lands, so
   a crashed idle prompt doesn't leave an orphan one-message session."
  (var last-saved (or initial-last-saved 0))
  (fn []
    (when (and backend session (assistant-present? agent.messages))
      (while (< last-saved (length agent.messages))
        (set last-saved (+ last-saved 1))
        (backend.append session (. agent.messages last-saved))))))

(local SESSION-LIFECYCLE-OWNER :session_persistence)

(fn emit-agent-started [agent opts]
  "Emit sanitized process/run startup metadata. Avoid passing raw opts because
   it may contain internal or sensitive fields."
  (events.emit {:type :agent-started
                    :agent agent
                    :provider opts.provider
                    :model agent.model
                    :cwd (cwd)}))

(fn emit-agent-shutdown [agent reason ?error]
  (events.emit {:type :agent-shutdown
                    :agent agent
                    :reason (or reason :normal)
                    :error ?error}))

(fn install-session-lifecycle! [state]
  "Bridge :message-appended into the existing session flush closure.
   The closure is looked up through mutable state so /new, /resume, /reload,
   /model, and /handoff do not need to reattach per-agent callbacks."
  (register-registry.unregister-by-owner SESSION-LIFECYCLE-OWNER)
  (events.on
    :message-appended
    (fn [ev]
      (when (= ev.agent state.agent)
        (when state.flush (state.flush))
        (when state.update-queue-status (state.update-queue-status))))
    SESSION-LIFECYCLE-OWNER))

;; Core/provider/util modules eligible for in-process /reload. Excludes
;; persistent-state modules such as :fen.core.extensions.state and every
;; extension-private state table. Extension reload is manifest-driven through
;; fen.core.extensions.loader, so main does not enumerate extension modules.
;; Edits to the executing run-presenter loop body itself still need a restart,
;; since that invocation is already on the stack.
(local RELOADABLE
  [:fen.version
   :fen.provider_help
   :fen.turn_lifecycle
   :fen.core.types
   :fen.core.diagnostics
   :fen.core.settings :fen.core.thinking
   :fen.core.llm :fen.core.llm.event_stream :fen.core.llm.models
   :fen.core.tools :fen.core.agent
   :fen.core.prompt :fen.core.docs.contracts :fen.core.llm.retry
   :fen.core.extensions.util :fen.core.extensions.events
   :fen.core.extensions.register.tool :fen.core.extensions.register.command
   :fen.core.extensions.register.control :fen.core.extensions.register.status
   :fen.core.extensions.register.panel :fen.core.extensions.register.hook
   :fen.core.extensions.register.introspect
   :fen.core.extensions.register.provider :fen.core.extensions.register.auth_backend
   :fen.core.extensions.register.session_backend
   :fen.core.extensions.register.prompt :fen.core.extensions.register.presenter
   :fen.core.extensions.register :fen.core.extensions.loader.api
   :fen.core.extensions.loader.manifest
   :fen.core.extensions.loader.discover
   :fen.core.extensions.loader.reload
   :fen.core.extensions.loader
   :fen.core.extensions.rocks
   :fen.script_runner
   :fen.extensions.provider_openai.openai_completions
   :fen.extensions.provider_openai.openai_responses_shared
   :fen.extensions.provider_openai.openai_responses
   :fen.extensions.provider_openai.openai_codex_responses
   :fen.extensions.provider_anthropic.anthropic_messages
   :fen.extensions.provider_openai.openai_codex_keychain
   :fen.extensions.provider_openai.openai_codex_oauth
   :fen.extensions.session_jsonl :fen.extensions.session_jsonl.session
   :fen.util.base64 :fen.util.path :fen.util.checksum :fen.util.sse
   :fen.util.json :fen.util.log :fen.util.process :fen.util.random
   :fen.util.id :fen.util.text
   :fen.util.sha256 :fen.util.search.bitap
   :fen.util.http :fen.util.http.backend :fen.util.http.backends.native])

(fn manual-reload! [modname]
  "Re-require modname and copy its new exports onto the original module
   table in place, so any prior `(local foo (require modname))` capture
   sees the new functions. Mirrors fennel.reload's mutation trick but
   works on already-compiled `dist/*.lua` modules too."
  (let [old (. package.loaded modname)]
    (tset package.loaded modname nil)
    (let [(ok? new) (pcall require modname)]
      (if (not ok?)
          (do (tset package.loaded modname old)
              (values false new))
          (do
            (when (and (= (type old) :table) (= (type new) :table))
              (each [k _ (pairs old)] (tset old k nil))
              (each [k v (pairs new)] (tset old k v))
              (tset package.loaded modname old))
            (values true nil))))))

(local reload-fingerprints {})

(fn module-changed?! [modname]
  "Return true when modname's runtime file fingerprint differs from the last
   snapshot, then update the snapshot. Missing prior snapshot initializes as
   unchanged so first startup load doesn't look dirty."
  (let [fp (checksum.module-fingerprint modname)
        key (tostring modname)]
    (if (not fp)
        false
        (let [old (. reload-fingerprints key)]
          (tset reload-fingerprints key fp.fingerprint)
          (and old (not= old fp.fingerprint))))))

(fn snapshot-reloadable! []
  (each [_ m (ipairs RELOADABLE)]
    (when (. package.loaded m)
      (module-changed?! m))))

(fn reload-modules! [?yield]
  (var ok-count 0)
  (var changed-count 0)
  (let [failures []
        changed-modules []]
    (each [_ m (ipairs RELOADABLE)]
      (when (. package.loaded m)
        (let [changed? (module-changed?! m)
              (ok? err) (manual-reload! m)]
          (if ok?
              (do
                (set ok-count (+ ok-count 1))
                (when changed?
                  (set changed-count (+ changed-count 1))
                  (table.insert changed-modules m)))
              (table.insert failures (.. m ": " (tostring err)))))
        (when (and ?yield (= (% ok-count 8) 0))
          (?yield {:phase :core :module m}))))
    (when (and ?yield (not= (% ok-count 8) 0))
      (?yield {:phase :core :module :done}))
    (values ok-count failures
            {:reloaded ok-count
             :changed changed-count
             :changed-modules changed-modules
             :failed (length failures)})))

(fn queue-depth [q] (length (or q [])))

(fn drain-queue! [q mode]
  (if (= mode :all)
      (let [out []]
        (while (> (length q) 0)
          (table.insert out (table.remove q 1)))
        out)
      (if (> (length q) 0)
          [(table.remove q 1)]
          [])))

(fn follow-up-line? [line]
  (= (string.sub (or line "") 1 1) ">"))

(fn strip-follow-up-prefix [line]
  (let [s (string.sub (or line "") 2)]
    (or (string.match s "^%s*(.-)%s*$") "")))

(fn approx-tokens [s]
  (if (or (= s nil) (= s ""))
      0
      (math.ceil (/ (length (tostring s)) 4))))

(fn err-first-line [s]
  (let [text (tostring (or s ""))
        i (string.find text "\n" 1 true)]
    (if i (string.sub text 1 (- i 1)) text)))

(fn safe-json [v]
  (let [(ok? s) (pcall json.encode v)]
    (if ok? s (tostring v))))

(fn content-tokens [content]
  (if (= content nil)
      0
      (= (type content) :string)
      (approx-tokens content)
      (do
        (var n 0)
        (each [_ block (ipairs content)]
          (if (= block.type :text)
              (set n (+ n (approx-tokens block.text)))
              (= block.type :thinking)
              (set n (+ n (approx-tokens block.thinking)))
              (= block.type :tool-call)
              (set n (+ n
                        (approx-tokens block.name)
                        (approx-tokens (safe-json (or block.arguments {})))))))
        n)))

(fn estimated-context-tokens [agent]
  (var n (approx-tokens (?. agent :system-prompt)))
  (each [_ msg (ipairs (or (?. agent :messages) []))]
    (set n (+ n (approx-tokens msg.role) (content-tokens msg.content)))
    (when (= msg.role :tool-result)
      (set n (+ n (approx-tokens msg.tool-name)))))
  n)

(fn run-presenter [opts]
  ;; Load bundled local extensions and any external extensions. The active
  ;; presenter registers itself through core.extensions, so main does not
  ;; need to know whether it is TUI, print, REPL, RPC, etc.; presenter-specific
  ;; lifecycle stays inside the extension.
  (extension-loader.load! opts {:interactive? true})
  (models-mod.register-providers!)
  (snapshot-reloadable!)
  (let [on-event (fn [ev] (events.emit ev))
        _state-box {:state nil}
        update-queue-status! (fn []
                               (let [st _state-box.state]
                                 (when st
                                   (events.emit
                                     {:type :set-status-info
                                      :info {:steering-queued (queue-depth st.steering-queue)
                                             :follow-up-queued (queue-depth st.follow-up-queue)
                                             :approx-context (estimated-context-tokens st.agent)}}))))
        agent-extra {:get-steering
                     (fn []
                       (let [st _state-box.state
                             out (if st (drain-queue! st.steering-queue st.steering-mode) [])]
                         (update-queue-status!)
                         out))
                     :get-follow-up
                     (fn []
                       (let [st _state-box.state
                             out (if st (drain-queue! st.follow-up-queue st.follow-up-mode) [])]
                         (update-queue-status!)
                         out))
                     :tool-context
                     (fn [_agent]
                       {:state _state-box.state})}
        backend (resolve-session-backend opts)
        agent (make-agent-from-opts opts on-event agent-extra)
        (session replayed) (start-session opts agent backend)
        flush (make-flush backend agent session replayed)
        ;; Mutable container so reloadable command handlers can swap the agent
        ;; record after /reload or replace the session after /new while the
        ;; on-submit closure keeps a live view. `busy?`/`turn` track the
        ;; in-flight agent coroutine so the on-tick callback can resume it
        ;; and slash commands can gate mutating operations. `cancel-requested?`
        ;; is the cancel-token the agent coroutine polls at every yield.
        state {: opts : on-event : agent : session : flush
               :session-backend backend
               : make-agent-from-opts
               :open-session (fn [opts]
                               (let [st _state-box.state]
                                 (open-session opts st.session-backend)))
               :open-existing-session (fn [ref ?yield-fn]
                                        (let [st _state-box.state]
                                          (when st.session-backend
                                            (st.session-backend.open-existing ref ?yield-fn))))
               :close-session (fn [session]
                                (let [st _state-box.state]
                                  (close-session st.session-backend session)))
               :make-flush (fn [agent session ?last-saved]
                             (let [st _state-box.state]
                               (make-flush st.session-backend agent session ?last-saved)))
               :load-session (fn [ref ?yield-fn]
                               (let [st _state-box.state]
                                 (when st.session-backend
                                   (st.session-backend.load ref ?yield-fn))))
               :find-session (fn [cwd target ?yield-fn]
                               (let [st _state-box.state]
                                 (when st.session-backend
                                   (st.session-backend.find cwd target ?yield-fn))))
               :list-sessions (fn [cwd limit ?yield-fn]
                                (let [st _state-box.state]
                                  (if st.session-backend
                                      (st.session-backend.list cwd limit ?yield-fn)
                                      [])))
               :session-info (fn [session]
                               (let [st _state-box.state]
                                 (backend-info st.session-backend session)))
               :reload-modules reload-modules!
               :load-extensions
               (fn [opts mode] (extension-loader.load! opts mode))
               :reload-extension
               (fn [name] (extension-loader.reload-extension! name))
               :reload-model-providers
               (fn [] (models-mod.register-providers!))
               :agent-extra agent-extra
               :update-queue-status update-queue-status!
               :steering-queue []
               :follow-up-queue []
               :steering-mode :one-at-a-time
               :follow-up-mode :one-at-a-time
               :busy? false
               :turn nil
               :turn-result nil
               :turn-error nil
               :cancel-requested? false}
        cancel-fn (fn [] state.cancel-requested?)
        is-busy? (fn [] state.busy?)
        request-cancel (fn []
                         (when state.busy?
                           (set state.cancel-requested? true)))
        on-submit (fn [line]
                    (if (= (string.sub line 1 1) "/")
                        (command-registry.dispatch line state)
                        state.busy?
                        (let [follow? (follow-up-line? line)
                              text (if follow? (strip-follow-up-prefix line) line)]
                          (if follow?
                              (table.insert state.follow-up-queue text)
                              (table.insert state.steering-queue text))
                          (update-queue-status!)
                          (events.emit
                            {:type :queued
                             :queue (if follow? :follow-up :steering)
                             :text text}))
                        (do
                          (set state.cancel-requested? false)
                          (set state.turn-result nil)
                          (set state.turn-error nil)
                          (set state.turn
                               (coroutine.create
                                 (fn []
                                   (agent-mod.step
                                     state.agent line cancel-fn))))
                          (set state.busy? true))))
        on-tick (fn []
                  (when state.turn
                    (let [(ok? value) (coroutine.resume state.turn)]
                      (when (not ok?)
                        (events.emit
                          {:type :error
                           :error (.. "agent task: " (err-first-line value))
                           :traceback (debug.traceback state.turn (tostring value))}))
                      (when (or (not ok?)
                                (= (coroutine.status state.turn) :dead))
                        (if ok?
                            (set state.turn-result value)
                            (set state.turn-error value))
                        (set state.busy? false)
                        (set state.turn nil)
                        (set state.cancel-requested? false)
                        ;; The agent flushes each message as it appends it;
                        ;; this final call is kept as a harmless safety net
                        ;; for older/reloaded agents without the hook.
                        (state.flush)
                        (turn-lifecycle.emit-complete! state ok? value)))))]
    (set _state-box.state state)
    (install-session-lifecycle! state)
    (when (> replayed 0) (state.flush))
    (let [(init-ok? init-err)
          (presenter-registry.init-active-presenter {:state state})]
      (when (not init-ok?)
        (close-session state.session-backend state.session)
        (emit-agent-shutdown state.agent :crashed init-err)
        (register-registry.unregister-by-owner SESSION-LIFECYCLE-OWNER)
        (io.stderr:write (.. "presenter init failed: "
                            (tostring init-err) "\n"))
        (os.exit 1)))
    (emit-agent-started state.agent opts)
    ;; Populate presenter status through the bus so the presenter is the
    ;; only thing that touches its own status state. The TUI subscriber
    ;; tolerates being called before/after init.
    (events.emit
      {:type :set-status-info
       :info {:provider opts.provider :model agent.model
              :thinking-status agent.thinking-status
              :steering-queued 0 :follow-up-queued 0
              :approx-context (estimated-context-tokens agent)}})
    (let [presenter-ctx {:state state
                         :on-submit on-submit
                         :on-tick on-tick
                         :request-cancel request-cancel
                         :is-busy? is-busy?
                         ;; Diagnostic hook: presenters that want to dump
                         ;; the in-flight agent coroutine on a stall can
                         ;; read it through this thunk without coupling
                         ;; to main's state shape.
                         :get-turn (fn [] state.turn)}
          (ok? err) (xpcall
                      #(let [(run-ok? run-err)
                             (presenter-registry.run-active-presenter presenter-ctx)]
                         (when (not run-ok?)
                           (error run-err)))
                      debug.traceback)
          (shutdown-ok? shutdown-err)
          (presenter-registry.shutdown-active-presenter presenter-ctx)]
      (when (not shutdown-ok?)
        (io.stderr:write (.. "presenter shutdown failed: "
                            (tostring shutdown-err) "\n"))
        ;; Defensive: if the presenter slot was lost (e.g. a botched
        ;; reload) the TUI's own shutdown never runs, leaving termbox2
        ;; holding the terminal in raw/no-echo mode. Force the teardown
        ;; here so the user's shell stays usable.
        (let [(ok-state? tui-state) (pcall require :fen.extensions.tui.state)
              (ok-tb? termbox2) (pcall require :termbox2)
              (ok-sink? log-sink) (pcall require :fen.util.log_sink)]
          (when (and ok-state? ok-tb? tui-state.tb-initialized?)
            (pcall (fn [] (termbox2.shutdown)))
            (set tui-state.tb-initialized? false)
            (when ok-sink? (pcall log-sink.close!)))))
      (close-session state.session-backend state.session)
      (emit-agent-shutdown state.agent (if ok? :normal :crashed) (when (not ok?) err))
      (register-registry.unregister-by-owner SESSION-LIFECYCLE-OWNER)
      (when (not ok?)
        (io.stderr:write (.. "presenter crashed: " (tostring err) "\n"))
        (os.exit 1)))))

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
  (let [parsed (parse-args argv)]
    (when parsed.help? (io.write USAGE) (os.exit 0))
    (when parsed.version? (io.write (.. (version-line) "\n")) (os.exit 0))
    (ensure-runtime!)
    (let [opts (apply-defaults parsed)]
      ;; Load non-interactive extensions before provider resolution so
      ;; extension-contributed providers/auth backends are selectable at
      ;; startup. Interactive-only extensions (notably TUI) are still loaded
      ;; later by run-presenter.
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
      (run-presenter opts))))

(main arg)
