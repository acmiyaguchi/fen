(local agent-mod (require :core.agent))
(local session-mod (require :core.session))
(local resource-loader (require :core.resource_loader))
(local system-prompt (require :core.system_prompt))
(local tools-mod (require :core.tools))
(local models-mod (require :core.models))
(local extensions (require :core.extensions))
(local extension-loader (require :core.extension_loader))
;; Side-effect require: loading this triggers (api.register :command ...)
;; for every built-in. /reload re-runs this module body so renamed/removed
;; commands don't leak.
(require :core.builtin_commands)
(local codex-auth (require :auth.openai_codex))
(local log (require :util.log))

(local USAGE
"agent-fennel — minimal Lua/Fennel coding agent

Usage:
  agent-fennel [options]
  agent-fennel --print \"your prompt\"

Options:
  --provider NAME      openai | openai-responses | openai-codex |
                       anthropic | <custom from models.json>
                       (default: openai). openai-codex uses your
                       ChatGPT subscription via pi-mono OAuth — run
                       `pi login openai-codex` once first.
  --model NAME         Model id (default: gpt-5.5 for openai,
                       openai-responses, openai-codex; claude-sonnet-4-6
                       for anthropic; or the first model declared for a
                       custom provider)
  --system TEXT        System prompt
  --max-tokens N       Reply token cap (default: 16384). Reasoning models
                       (gpt-5*, o1, o3) charge their thinking against this
                       cap, so 1024 leaves nothing for visible output.
  --thinking-budget N  Anthropic only: enable extended thinking with N tokens
  --reasoning-effort E  OpenAI Responses / Codex: minimal | low | medium |
                       high | xhigh. Clamped per-model where the API
                       refuses some values (e.g. gpt-5.5 minimal → low).
  --print TEXT         One-shot mode; prints final assistant text and exits
  --continue           Resume the most recent session for the current cwd
  --no-session         Do not write a transcript to disk
  --skill PATH         Additional skill file or directory (repeatable)
  --skills DIR         Backward-compatible alias for --skill DIR
  --extension PATH     Load an external extension file or directory
                       (repeatable; dir expects init.fnl or init.lua)
  -h, --help           Show this help

Slash commands (interactive mode):
  /new                 Reset the current conversation and start a fresh session.
  /reload              Hot-reload core modules (run `make build` first).
                       Session messages are preserved. Also re-reads
                       ~/.config/agent-fennel/models.json.
  /status              Show model, provider, message count, and token usage
  /expand [on|off]     Toggle collapsed vs full tool-result bodies
  /markdown [on|off]   Toggle block-level Markdown rendering of assistant text
  /thinking [on|off]   Show or hide assistant thinking blocks
  /queue               Show or clear queued steering/follow-up messages
  /cancel-all          Cancel current turn and clear queues
  /help                Show available commands

Environment:
  OPENAI_API_KEY       Required when --provider=openai
  ANTHROPIC_API_KEY    Required when --provider=anthropic
  AGENT_FENNEL_LOG     debug | info | warn | error (default: info)
  XDG_STATE_HOME       Sessions dir (default: ~/.local/state/agent-fennel)
  XDG_CONFIG_HOME      User skills + models.json dir
                       (default: ~/.config/agent-fennel)
  FEN_EXTENSIONS_PATH  Colon-separated extension discovery roots

Custom providers:
  Add Ollama, vLLM, LM Studio, or any OpenAI-compatible endpoint by writing
  ~/.config/agent-fennel/models.json. See docs or pi-mono's models.md for the
  schema. Edits are picked up via /reload (no restart required).
")

(local PROVIDER-API
  {:openai :openai-completions
   :openai-responses :openai-responses
   :openai-codex :openai-codex-responses
   :anthropic :anthropic-messages})

(local DEFAULT-MODELS
  {:openai :gpt-5.5
   :openai-responses :gpt-5.5
   :openai-codex :gpt-5.5
   :anthropic :claude-sonnet-4-6})

;; openai-codex intentionally absent: Codex auth is OAuth credentials
;; from ~/.pi/agent/auth.json, resolved separately in resolve-provider-config.
(local API-KEY-VARS
  {:openai :OPENAI_API_KEY
   :openai-responses :OPENAI_API_KEY
   :anthropic :ANTHROPIC_API_KEY})

(fn resolve-provider-config [opts]
  "Returns a record describing the provider to use for this run:
   {:name :api :model :api-key :base-url :compat}.

   models.json takes precedence: a `--provider X` flag matches an entry
   under `providers.X` in the config and that wins, even if X is also a
   built-in name. (This lets users route the built-in `openai` provider
   through a proxy by redefining it in models.json — see
   `coding-agent/docs/models.md` 'Overriding Built-in Providers'.)

   Built-in providers require their env-var. Custom providers may have
   no api-key at all (Ollama-style local servers)."
  (let [name opts.provider
        custom (models-mod.get-provider name)]
    (if custom
        {: name
         :api (or custom.api (. PROVIDER-API name))
         :model (or opts.model (models-mod.first-model-id custom))
         :api-key custom.api-key
         :base-url custom.base-url
         :compat custom.compat}
        (let [api (. PROVIDER-API name)]
          (when (not api)
            (io.stderr:write
              (.. "unknown --provider: " (tostring name)
                  " (expected openai | openai-responses | openai-codex |"
                  " anthropic, or a name defined in "
                  "~/.config/agent-fennel/models.json)\n"))
            (os.exit 2))
          (if (= name :openai-codex)
              ;; Codex uses OAuth credentials from ~/.pi/agent/auth.json
              ;; (populated by `pi login openai-codex`). We refresh
              ;; tokens lazily here so the agent loop never sees a
              ;; stale Bearer token.
              (let [(ok? creds) (pcall codex-auth.get-fresh-creds!)]
                (when (not ok?)
                  (io.stderr:write (.. (tostring creds) "\n"))
                  (os.exit 1))
                {: name : api :api-key nil
                 :model (or opts.model (. DEFAULT-MODELS name))
                 :base-url nil :compat nil :creds creds})
              (let [key-var (. API-KEY-VARS name)
                    api-key (os.getenv key-var)]
                (when (or (not api-key) (= api-key ""))
                  (io.stderr:write (.. (tostring key-var) " not set\n"))
                  (os.exit 1))
                {: name : api :api-key api-key
                 :model (or opts.model (. DEFAULT-MODELS name))
                 :base-url nil :compat nil}))))))

(fn parse-args [argv]
  ;; Don't pre-fill :max-tokens here — keep it nil unless the user passes
  ;; --max-tokens, so the default lives in make-agent's `(or max-tokens N)`
  ;; fallback. That way /reload picks up a changed default without a
  ;; restart.
  (let [opts {:provider :openai :extra-skill-paths [] :extension-paths []}]
    (var i 1)
    (while (<= i (length argv))
      (let [a (. argv i)]
        (if (or (= a :-h) (= a :--help))
            (do (set opts.help? true) (set i (+ i 1)))
            (= a :--provider)
            (do (set opts.provider (. argv (+ i 1))) (set i (+ i 2)))
            (= a :--model)
            (do (set opts.model (. argv (+ i 1))) (set i (+ i 2)))
            (= a :--system)
            (do (set opts.system (. argv (+ i 1))) (set i (+ i 2)))
            (= a :--max-tokens)
            (do (set opts.max-tokens (tonumber (. argv (+ i 1)))) (set i (+ i 2)))
            (= a :--thinking-budget)
            (do (set opts.thinking-budget (tonumber (. argv (+ i 1))))
                (set i (+ i 2)))
            (= a :--reasoning-effort)
            (do (set opts.reasoning-effort (. argv (+ i 1)))
                (set i (+ i 2)))
            (= a :--print)
            (do (set opts.print (. argv (+ i 1))) (set i (+ i 2)))
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
    opts))

(fn build-system-prompt [opts loader agent-tools]
  (system-prompt.build opts loader
                       (or agent-tools
                           (extensions.merged-tools tools-mod.registry))))

(fn make-agent-from-opts [opts on-event loader extra]
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
    (let [agent-tools (extensions.merged-tools tools-mod.registry)
          spec {:provider-api cfg.api
                :model cfg.model
                :system (build-system-prompt opts loader agent-tools)
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

(fn maybe-resume [opts agent]
  "If --continue, replay the latest session's messages into agent.messages
   so the next step has full prior context. Returns the count of replayed
   messages so the session writer can skip re-saving them."
  (if (not opts.continue?)
      0
      (let [path (session-mod.latest-for-cwd (cwd))]
        (if (not path)
            (do (log.warn "session: --continue but no prior session found")
                0)
            (let [msgs (session-mod.load path)]
              (each [_ m (ipairs msgs)]
                (table.insert agent.messages m))
              (length msgs))))))

(fn make-flush [agent session]
  "Returns a closure that appends any messages added since the last call.
   Tracks `last-saved` across invocations."
  (var last-saved 0)
  (fn []
    (when session
      (while (< last-saved (length agent.messages))
        (set last-saved (+ last-saved 1))
        (session-mod.append session (. agent.messages last-saved))))))

(fn run-print [opts loader]
  ;; Route events through the bus so extensions registered for --print can
  ;; observe them. The built-in stderr error formatter is just another
  ;; subscriber.
  (extension-loader.load! opts {:interactive? false})
  (extensions.on :error
                 (fn [ev]
                   (io.stderr:write (.. "error: " (tostring ev.error) "\n"))))
  (let [agent (make-agent-from-opts
                opts
                (fn [ev] (extensions.emit ev))
                loader)
        session (open-session opts)
        replayed (maybe-resume opts agent)
        flush (make-flush agent session)]
    ;; Replayed messages came from disk — mark them already-saved so we don't
    ;; re-write them.
    (when (> replayed 0) (flush))
    (let [(ok? result) (xpcall #(agent-mod.step agent opts.print) debug.traceback)]
      (flush)
      (session-mod.close session)
      (if ok?
          (print result)
          (do (io.stderr:write (.. "agent crashed: " (tostring result) "\n"))
              (os.exit 1))))))

;; Core modules eligible for in-process /reload. Excludes persistent-state
;; modules such as :core.extensions_state and extension-private state tables.
;; First-party/external extension module reload is delegated to
;; core.extension_loader, so main does not enumerate presenter-specific
;; modules here. Edits to the executing run-interactive loop body itself still
;; need a restart, since that invocation is already on the stack.
(local RELOADABLE
  [:version
   :core.types :core.llm :core.event_stream :core.tools :core.agent
   :core.session :core.skills :core.resource_loader :core.system_prompt
   :core.models :core.extensions :core.builtin_commands
   :providers.openai_completions :providers.openai_responses
   :providers.openai_responses_shared :providers.openai_codex_responses
   :providers.anthropic_messages
   :auth.storage :auth.openai_codex :util.base64
   :core.extension_loader
   :util.sse :util.json :util.log])

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

(fn reload-modules! []
  (var ok-count 0)
  (let [failures []]
    (each [_ m (ipairs RELOADABLE)]
      (when (. package.loaded m)
        (let [(ok? err) (manual-reload! m)]
          (if ok?
              (set ok-count (+ ok-count 1))
              (table.insert failures (.. m ": " (tostring err)))))))
    (values ok-count failures)))

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

(fn run-interactive [opts loader]
  ;; Load bundled local extensions and any external extensions. The active
  ;; presenter registers itself through core.extensions, so main does not
  ;; need to know whether it is TUI, REPL, RPC, etc.; termbox-specific
  ;; lifecycle stays inside the TUI extension.
  (extension-loader.load! opts {:interactive? true})
  (let [on-event (fn [ev] (extensions.emit ev))
        _state-box {:state nil}
        update-queue-status! (fn []
                               (let [st _state-box.state]
                                 (when st
                                   (extensions.emit
                                     {:type :set-status-info
                                      :info {:steering-queued (queue-depth st.steering-queue)
                                             :follow-up-queued (queue-depth st.follow-up-queue)}}))))
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
        agent (make-agent-from-opts opts on-event loader agent-extra)
        session (open-session opts)
        replayed (maybe-resume opts agent)
        flush (make-flush agent session)
        ;; Mutable container so reloadable command handlers can swap the agent
        ;; record after /reload or replace the session after /new while the
        ;; on-submit closure keeps a live view. `busy?`/`turn` track the
        ;; in-flight agent coroutine so the on-tick callback can resume it
        ;; and slash commands can gate mutating operations. `cancel-requested?`
        ;; is the cancel-token the agent coroutine polls at every yield.
        state {: opts : loader : on-event : agent : session : flush
               : make-agent-from-opts
               :resource-loader resource-loader
               :open-session open-session
               :make-flush make-flush
               :reload-modules reload-modules!
               :load-extensions
               (fn [opts mode] (extension-loader.load! opts mode))
               :reload-extension
               (fn [name] (extension-loader.reload-extension! name))
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
                                   (agent-mod.step-coop
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
                        ;; Cancellation rolls agent.messages back to the
                        ;; pre-turn length, so flush is a no-op in that
                        ;; case — but still safe to call (flush appends
                        ;; only newly-added messages).
                        (state.flush)))))]
    (set _state-box.state state)
    (when (> replayed 0) (state.flush))
    (let [(init-ok? init-err)
          (extensions.init-active-presenter {:state state})]
      (when (not init-ok?)
        (session-mod.close state.session)
        (io.stderr:write (.. "presenter init failed: "
                            (tostring init-err) "\n"))
        (os.exit 1)))
    ;; Populate presenter status through the bus so the presenter is the
    ;; only thing that touches its own status state. The TUI subscriber
    ;; tolerates being called before/after init.
    (extensions.emit
      {:type :set-status-info
       :info {:provider opts.provider :model agent.model
              :steering-queued 0 :follow-up-queued 0}})
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
                            (tostring shutdown-err) "\n")))
      (session-mod.close state.session)
      (when (not ok?)
        (io.stderr:write (.. "presenter crashed: " (tostring err) "\n"))
        (os.exit 1)))))

(fn main [argv]
  (let [opts (parse-args argv)]
    (when opts.help? (io.write USAGE) (os.exit 0))
    ;; Validate config + auth eagerly so misconfiguration fails before we
    ;; spin up the TUI or open a session file. The same call runs again
    ;; inside make-agent-from-opts; resolve-provider-config is cheap and
    ;; idempotent.
    (resolve-provider-config opts)
    (let [loader (resource-loader.make opts)]
      (if opts.print
          (run-print opts loader)
          (run-interactive opts loader)))))

(main arg)
