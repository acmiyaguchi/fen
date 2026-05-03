(var agent-mod nil)
(var session-mod nil)
(var system-prompt nil)
(var llm nil)
(var models-mod nil)
(var settings nil)
(var extensions nil)
(var extension-loader nil)
(var checksum nil)
(var json nil)
(var log nil)
(var rocks nil)

(fn ensure-rocks! []
  (when (not rocks)
    (set rocks (require :fen.core.extensions.rocks)))
  rocks)

(fn ensure-runtime! []
  "Load runtime modules lazily so `fen --help` can run from the single-file
   prototype without loading JSON/HTTP/TUI/provider C dependencies."
  (when (not agent-mod)
    (set agent-mod (require :fen.core.agent))
    (set session-mod (require :fen.core.session))
    (set system-prompt (require :fen.core.prompt))
    (set llm (require :fen.core.llm))
    (set models-mod (require :fen.core.llm.models))
    (set settings (require :fen.core.settings))
    (set extensions (require :fen.core.extensions))
    (set extension-loader (require :fen.core.extensions.loader))
    (set checksum (require :fen.util.checksum))
    (set json (require :fen.util.json))
    (set log (require :fen.util.log))))

(local USAGE
"fen — minimal Lua/Fennel coding agent

Usage:
  fen [options]
  fen --print \"your prompt\"
  fen ext build <dir>

Options:
  --provider NAME      openai | openai-responses | openai-codex |
                       anthropic | <custom from models.json>
                       (default: saved setting, else openai).
                       openai-codex uses your
                       ChatGPT subscription via pi-mono OAuth — run
                       `pi login openai-codex` once first.
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
  --thinking-budget N  Anthropic only: enable extended thinking with N tokens
  --reasoning-effort E  OpenAI Responses / Codex: minimal | low | medium |
                       high | xhigh. Clamped per-model where the API
                       refuses some values (e.g. gpt-5.5 minimal → low).
  --print TEXT         One-shot mode; prints final assistant text and exits
  --presenter NAME     Interactive presenter: tui | web (default: tui)
  --continue           Resume the most recent session for the current cwd
  --no-session         Do not write a transcript to disk
  --skill PATH         Additional skill file or directory (repeatable)
  --skills DIR         Backward-compatible alias for --skill DIR
  --extension PATH     Load an external extension file or directory
                       (repeatable; dir expects init.fnl or init.lua)
  --dev-path DIR       Single-file binary only: prepend a Lua module
                       root so .fnl/.lua in DIR shadow the embedded
                       archive (repeatable). Consumed by the launcher.
  --extension-root DIR Single-file binary only: walk DIR for extension
                       manifests (repeatable). Folded into
                       FEN_EXTENSIONS_PATH; consumed by the launcher.
  -h, --help           Show this help

Subcommands:
  ext build DIR        Build a drop-in extension's rockspec into the fen
                       rocks tree (${XDG_DATA_HOME:-~/.local/share}/fen/rocks,
                       or FEN_ROCKS_TREE) using the bundled local-only
                       LuaRocks runtime.

Slash commands (interactive mode):
  /new                 Reset the current conversation and start a fresh session.
  /handoff [guidance]  Summarize this session and seed a fresh session with it.
                       Optional guidance controls emphasis/format.
  /reload              Hot-reload core modules and source overlays.
                       Session messages are preserved. Also re-reads
                       ~/.config/fen/models.json.
  /status              Show model, provider, message count, and token usage
  /model [index|query] Show available models; switch by list index or name
  /mem                 Show runtime memory diagnostics
  /prompt              Show system-prompt fragments
  /prompt rendered     Show the rendered system prompt
  /expand [on|off]     Toggle collapsed vs full tool-result bodies
  /markdown [on|off]   Toggle block-level Markdown rendering of assistant text
  /thinking [on|off]   Show or hide assistant thinking blocks
  /queue               Show or clear queued steering/follow-up messages
  /cancel-all          Cancel current turn and clear queues
  /help                Show available commands

Environment:
  OPENAI_API_KEY       Required when --provider=openai
  ANTHROPIC_API_KEY    Required when --provider=anthropic
  FEN_LOG              debug | info | warn | error (default: info)
  XDG_STATE_HOME       Sessions dir (default: ~/.local/state/fen)
  XDG_CONFIG_HOME      User skills, models.json, and settings.json dir
                       (default: ~/.config/fen)
  FEN_EXTENSIONS_PATH  Colon-separated extension discovery roots
                       (--extension-root in the single-file binary
                       prepends to this list)
  FEN_ROCKS_TREE       Override the fen-managed LuaRocks tree used by
                       `fen ext build` and extension dependency loading
  FEN_DEV_PATH         Single-file binary only: colon-separated Lua
                       module roots prepended ahead of the embedded
                       archive (equivalent to repeated --dev-path)

Custom providers:
  Add Ollama, vLLM, LM Studio, or any OpenAI-compatible endpoint by writing
  ~/.config/fen/models.json. See docs or pi-mono's models.md for the
  schema. Edits are picked up via /reload (no restart required).

Settings:
  Default provider/model are read from ~/.config/fen/settings.json when
  CLI flags are omitted. The /model command writes this file.
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
        provider (extensions.find-provider name)]
    (if (not provider)
        (if opts.provider-from-settings?
            (fallback-from-settings!
              opts
              (.. "defaultProvider " (tostring name) " is not configured"))
            (do
              (io.stderr:write
                (.. "unknown --provider: " (tostring name)
                    " (expected openai | openai-responses | openai-codex |"
                    " anthropic, or a name defined in "
                    "~/.config/fen/models.json)\n"))
              (os.exit 2)))
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
              (let [backend (extensions.find-auth-backend provider.auth-backend)]
                (if (not backend)
                    (if opts.provider-from-settings?
                        (fallback-from-settings!
                          opts
                          (.. "defaultProvider " (tostring name)
                              " has missing auth backend "
                              (tostring provider.auth-backend)))
                        (do
                          (io.stderr:write
                            (.. "missing auth backend: "
                                (tostring provider.auth-backend) "\n"))
                          (os.exit 1)))
                    (let [(ok? creds) (pcall backend.get-fresh-creds!)]
                      (if (not ok?)
                          (if opts.provider-from-settings?
                              (fallback-from-settings!
                                opts
                                (.. "defaultProvider " (tostring name)
                                    " is unavailable: " (tostring creds)))
                              (do
                                (io.stderr:write (.. (tostring creds) "\n"))
                                (os.exit 1)))
                          {:name name :provider-name provider.name :api provider.api
                           :api-key nil :model model :base-url provider.base-url
                           :compat provider.compat :creds creds}))))
              (let [key-var provider.api-key-var
                    env-key (and key-var (os.getenv key-var))]
                (if (and key-var (or (not env-key) (= env-key "")))
                    (if opts.provider-from-settings?
                        (fallback-from-settings!
                          opts
                          (.. "defaultProvider " (tostring name)
                              " requires " (tostring key-var)))
                        (do
                          (io.stderr:write (.. (tostring key-var) " not set\n"))
                          (os.exit 1)))
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
              :extra-skill-paths [] :extension-paths []}]
    (var i 1)
    (while (<= i (length argv))
      (let [a (. argv i)]
        (if (or (= a :-h) (= a :--help))
            (do (set opts.help? true) (set i (+ i 1)))
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
            (= a :--thinking-budget)
            (do (set opts.thinking-budget (tonumber (. argv (+ i 1))))
                (set i (+ i 2)))
            (= a :--reasoning-effort)
            (do (set opts.reasoning-effort (. argv (+ i 1)))
                (set i (+ i 2)))
            (= a :--print)
            (do (set opts.print (. argv (+ i 1))) (set i (+ i 2)))
            (= a :--presenter)
            (do (set opts.presenter (. argv (+ i 1))) (set i (+ i 2)))
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
            (do (io.stderr:write (.. "unknown arg: " a "\n")) (os.exit 2)))))
    (when (and (not= opts.presenter :tui) (not= opts.presenter :web))
      (io.stderr:write (.. "unknown --presenter: " (tostring opts.presenter)
                          " (expected tui | web)\n"))
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
    opts))

(fn build-system-prompt [opts agent-tools]
  (system-prompt.build opts
                       (or agent-tools
                           (extensions.merged-tools []))))

(fn make-agent-from-opts [opts on-event extra]
  "Resolve the provider config (re-reads models.json each call so /reload
   picks up edits), then construct an Agent. The api-key, base-url, and
   compat fields ride through `:provider-options` into the provider's
   `complete`. Optional `extra` fields are forwarded to make-agent (used by
   interactive queue callbacks)."
  (let [cfg (resolve-provider-config opts)
        provider-options {}]
    (when cfg.base-url (set provider-options.base-url cfg.base-url))
    (when cfg.compat (set provider-options.compat cfg.compat))
    (when cfg.creds (set provider-options.creds cfg.creds))
    (when opts.thinking-budget
      (set provider-options.thinking-budget opts.thinking-budget))
    (when opts.reasoning-effort
      (set provider-options.reasoning-effort opts.reasoning-effort))
    (when opts.retry-max-attempts
      (set provider-options.retry-max-attempts opts.retry-max-attempts))
    (let [agent-tools (extensions.merged-tools [])
          spec {:provider-name cfg.provider-name
                :model cfg.model
                :system (build-system-prompt opts agent-tools)
                :api-key cfg.api-key
                :max-tokens opts.max-tokens
                :tools agent-tools
                : provider-options
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

(fn open-session [opts]
  "Open a transcript file for this run, unless --no-session is set."
  (if opts.no-session?
      nil
      (session-mod.open (cwd))))

(fn start-session [opts agent]
  "Open the active transcript and optionally replay --continue into the agent.
   Returns (session, replayed-count). --continue appends to the existing file
   instead of opening a new transcript."
  (if opts.continue?
      (let [p (session-mod.latest-for-cwd (cwd))]
        (if (not p)
            (do (log.warn "session: --continue but no prior session found")
                (values (open-session opts) 0))
            (let [msgs (session-mod.load p)]
              (each [_ m (ipairs msgs)]
                (table.insert agent.messages m))
              (values (if opts.no-session? nil (session-mod.open-existing p))
                      (length msgs)))))
      (values (open-session opts) 0)))

(fn assistant-present? [messages]
  (var found? false)
  (each [_ m (ipairs messages)]
    (when (= m.role :assistant)
      (set found? true)))
  found?)

(fn make-flush [agent session initial-last-saved]
  "Returns a closure that appends any messages added since the last call.
   Tracks `last-saved` across invocations. Like pi-mono, holds early user-only
   messages in memory until the first assistant (including :aborted) lands, so
   a crashed idle prompt doesn't leave an orphan one-message session."
  (var last-saved (or initial-last-saved 0))
  (fn []
    (when (and session (assistant-present? agent.messages))
      (while (< last-saved (length agent.messages))
        (set last-saved (+ last-saved 1))
        (session-mod.append session (. agent.messages last-saved))))))

(local SESSION-LIFECYCLE-OWNER :session_persistence)

(fn emit-agent-started [agent opts]
  "Emit sanitized process/run startup metadata. Avoid passing raw opts because
   it may contain internal or sensitive fields."
  (extensions.emit {:type :agent-started
                    :agent agent
                    :provider opts.provider
                    :model agent.model
                    :cwd (cwd)}))

(fn emit-agent-shutdown [agent reason ?error]
  (extensions.emit {:type :agent-shutdown
                    :agent agent
                    :reason (or reason :normal)
                    :error ?error}))

(fn install-session-lifecycle! [state]
  "Bridge :message-appended into the existing session flush closure.
   The closure is looked up through mutable state so /new, /resume, /reload,
   /model, and /handoff do not need to reattach per-agent callbacks."
  (extensions.unregister-by-owner SESSION-LIFECYCLE-OWNER)
  (extensions.on
    :message-appended
    (fn [ev]
      (when (= ev.agent state.agent)
        (when state.flush (state.flush))
        (when state.update-queue-status (state.update-queue-status))))
    SESSION-LIFECYCLE-OWNER))

(fn run-print [opts]
  ;; Route events through the bus so extensions registered for --print can
  ;; observe them. The built-in stderr error formatter is just another
  ;; subscriber.
  (extension-loader.load! opts {:interactive? false})
  (extensions.on :error
                 (fn [ev]
                   (io.stderr:write (.. "error: " (tostring ev.error) "\n"))))
  (let [agent (make-agent-from-opts
                opts
                (fn [ev] (extensions.emit ev)))
        (session replayed) (start-session opts agent)
        flush (make-flush agent session replayed)
        state {: agent : session : flush}]
    (install-session-lifecycle! state)
    (emit-agent-started agent opts)
    (let [(ok? result) (xpcall #(agent-mod.step agent opts.print) debug.traceback)]
      (flush)
      (session-mod.close session)
      (emit-agent-shutdown agent (if ok? :normal :crashed) (when (not ok?) result))
      (extensions.unregister-by-owner SESSION-LIFECYCLE-OWNER)
      (if ok?
          (print result)
          (do (io.stderr:write (.. "agent crashed: " (tostring result) "\n"))
              (os.exit 1))))))

;; Core/provider/util modules eligible for in-process /reload. Excludes
;; persistent-state modules such as :fen.core.extensions.state and every
;; extension-private state table. Extension reload is manifest-driven through
;; fen.core.extensions.loader, so main does not enumerate extension modules.
;; Edits to the executing run-interactive loop body itself still need a restart,
;; since that invocation is already on the stack.
(local RELOADABLE
  [:fen.version
   :fen.core.types
   :fen.core.settings
   :fen.core.llm :fen.core.llm.event_stream :fen.core.llm.models
   :fen.core.tools :fen.core.agent :fen.core.session
   :fen.core.prompt :fen.core.llm.retry
   :fen.core.extensions.util :fen.core.extensions.events
   :fen.core.extensions.register.tool :fen.core.extensions.register.command
   :fen.core.extensions.register.control :fen.core.extensions.register.status
   :fen.core.extensions.register.panel :fen.core.extensions.register.hook
   :fen.core.extensions.register.provider :fen.core.extensions.register.auth_backend
   :fen.core.extensions.register.prompt :fen.core.extensions.register.presenter
   :fen.core.extensions.register :fen.core.extensions
   :fen.core.extensions.loader.manifest
   :fen.core.extensions.loader.discover
   :fen.core.extensions.loader.reload
   :fen.core.extensions.loader
   :fen.core.extensions.rocks
   :fen.extensions.provider_openai.openai_completions
   :fen.extensions.provider_openai.openai_responses
   :fen.extensions.provider_openai.openai_responses_shared
   :fen.extensions.provider_openai_codex.openai_codex_responses
   :fen.extensions.provider_anthropic.anthropic_messages
   :fen.extensions.provider_openai_codex.openai_codex_keychain
   :fen.extensions.provider_openai_codex.openai_codex_oauth
   :fen.util.base64 :fen.util.path :fen.util.checksum :fen.util.sse
   :fen.util.json :fen.util.log :fen.util.process
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

(fn reload-modules! []
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
              (table.insert failures (.. m ": " (tostring err)))))))
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

(fn run-interactive [opts]
  ;; Load bundled local extensions and any external extensions. The active
  ;; presenter registers itself through core.extensions, so main does not
  ;; need to know whether it is TUI, REPL, RPC, etc.; termbox-specific
  ;; lifecycle stays inside the TUI extension.
  (extension-loader.load! opts {:interactive? true})
  (models-mod.register-providers!)
  (snapshot-reloadable!)
  (let [on-event (fn [ev] (extensions.emit ev))
        _state-box {:state nil}
        update-queue-status! (fn []
                               (let [st _state-box.state]
                                 (when st
                                   (extensions.emit
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
                         out))}
        agent (make-agent-from-opts opts on-event agent-extra)
        (session replayed) (start-session opts agent)
        flush (make-flush agent session replayed)
        ;; Mutable container so reloadable command handlers can swap the agent
        ;; record after /reload or replace the session after /new while the
        ;; on-submit closure keeps a live view. `busy?`/`turn` track the
        ;; in-flight agent coroutine so the on-tick callback can resume it
        ;; and slash commands can gate mutating operations. `cancel-requested?`
        ;; is the cancel-token the agent coroutine polls at every yield.
        state {: opts : on-event : agent : session : flush
               : make-agent-from-opts
               :open-session open-session
               :make-flush make-flush
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
               :cancel-requested? false}
        cancel-fn (fn [] state.cancel-requested?)
        is-busy? (fn [] state.busy?)
        request-cancel (fn []
                         (when state.busy?
                           (set state.cancel-requested? true)))
        on-submit (fn [line]
                    (if (= (string.sub line 1 1) "/")
                        (extensions.dispatch-command line state)
                        state.busy?
                        (let [follow? (follow-up-line? line)
                              text (if follow? (strip-follow-up-prefix line) line)]
                          (if follow?
                              (table.insert state.follow-up-queue text)
                              (table.insert state.steering-queue text))
                          (update-queue-status!)
                          (extensions.emit
                            {:type :queued
                             :queue (if follow? :follow-up :steering)
                             :text text}))
                        (do
                          (set state.cancel-requested? false)
                          (set state.turn
                               (coroutine.create
                                 (fn []
                                   (agent-mod.step
                                     state.agent line cancel-fn))))
                          (set state.busy? true))))
        on-tick (fn []
                  (when state.turn
                    (let [(ok? err) (coroutine.resume state.turn)]
                      (when (not ok?)
                        (extensions.emit
                          {:type :error
                           :error (.. "agent task: " (tostring err))}))
                      (when (or (not ok?)
                                (= (coroutine.status state.turn) :dead))
                        (set state.busy? false)
                        (set state.turn nil)
                        (set state.cancel-requested? false)
                        ;; The agent flushes each message as it appends it;
                        ;; this final call is kept as a harmless safety net
                        ;; for older/reloaded agents without the hook.
                        (state.flush)))))]
    (set _state-box.state state)
    (install-session-lifecycle! state)
    (when (> replayed 0) (state.flush))
    (let [(init-ok? init-err)
          (extensions.init-active-presenter {:state state})]
      (when (not init-ok?)
        (session-mod.close state.session)
        (emit-agent-shutdown state.agent :crashed init-err)
        (extensions.unregister-by-owner SESSION-LIFECYCLE-OWNER)
        (io.stderr:write (.. "presenter init failed: "
                            (tostring init-err) "\n"))
        (os.exit 1)))
    (emit-agent-started state.agent opts)
    ;; Populate presenter status through the bus so the presenter is the
    ;; only thing that touches its own status state. The TUI subscriber
    ;; tolerates being called before/after init.
    (extensions.emit
      {:type :set-status-info
       :info {:provider opts.provider :model agent.model
              :steering-queued 0 :follow-up-queued 0
              :approx-context (estimated-context-tokens agent)}})
    (let [presenter-ctx {:state state
                         :on-submit on-submit
                         :on-tick on-tick
                         :request-cancel request-cancel
                         :is-busy? is-busy?}
          (ok? err) (xpcall
                      #(let [(run-ok? run-err)
                             (extensions.run-active-presenter presenter-ctx)]
                         (when (not run-ok?)
                           (error run-err)))
                      debug.traceback)
          (shutdown-ok? shutdown-err)
          (extensions.shutdown-active-presenter presenter-ctx)]
      (when (not shutdown-ok?)
        (io.stderr:write (.. "presenter shutdown failed: "
                            (tostring shutdown-err) "\n"))
        ;; Defensive: if the presenter slot was lost (e.g. a botched
        ;; reload) the TUI's own shutdown never runs, leaving termbox2
        ;; holding the terminal in raw/no-echo mode. Force the teardown
        ;; here so the user's shell stays usable.
        (let [(ok-state? tui-state) (pcall require :fen.extensions.tui.state)
              (ok-tb? termbox2) (pcall require :termbox2)]
          (when (and ok-state? ok-tb? tui-state.tb-initialized?)
            (pcall (fn [] (termbox2.shutdown)))
            (set tui-state.tb-initialized? false))))
      (session-mod.close state.session)
      (emit-agent-shutdown state.agent (if ok? :normal :crashed) (when (not ok?) err))
      (extensions.unregister-by-owner SESSION-LIFECYCLE-OWNER)
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

(fn main [argv]
  (when (= (. argv 1) :ext)
    (run-ext-subcommand argv))
  (ensure-rocks!)
  (rocks.prepend-tree!)
  (let [parsed (parse-args argv)]
    (when parsed.help? (io.write USAGE) (os.exit 0))
    (ensure-runtime!)
    (let [opts (apply-defaults parsed)]
      ;; Load non-interactive extensions before provider resolution so
      ;; extension-contributed providers/auth backends are selectable at
      ;; startup. Interactive-only extensions (notably TUI) are still loaded
      ;; later by run-interactive.
      (extension-loader.load! opts {:interactive? false})
      (models-mod.register-providers!)
      ;; Validate config + auth eagerly so misconfiguration fails before we
      ;; spin up the TUI or open a session file. The same call runs again
      ;; inside make-agent-from-opts; resolve-provider-config is cheap and
      ;; idempotent.
      (resolve-provider-config opts)
      (if opts.print
          (run-print opts)
          (run-interactive opts)))))

(main arg)
