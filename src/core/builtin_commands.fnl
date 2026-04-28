;; Built-in slash commands.
;;
;; Each command registers via `(api.register :command {...})` against the
;; shared extension api at module load time. `extensions.dispatch-command`
;; (the lookup-and-pcall dispatcher in core.extensions) delegates to
;; whatever's been registered. Loading this module is a side-effect-only
;; operation — `require`ing it triggers the registrations.
;;
;; Handlers receive `(args state)` where `args` is the substring after the
;; command name and `state` is the run-interactive state record.
;;
;; This module no longer imports the TUI in any form. /new and /reload
;; ask the active presenter to clear/reinit/redraw via bus events
;; (`:reset-conversation`, `:reinit-presenter`, `:redraw`,
;; `:set-status-info`); the TUI subscribes to those in
;; `extensions/tui/init.fnl`. /expand, /markdown, /thinking moved
;; entirely into the TUI extension since they only mutate TUI state.
;; The contract from this side is one-way: built-in commands emit
;; events, presenters subscribe.

(local extensions (require :core.extensions))
(local session-mod (require :core.session))
(local json (require :util.json))

(local M {})

;; -----------------------------------------------------------------
;; Helpers shared across handlers
;; -----------------------------------------------------------------

(fn approx-tokens [s]
  "Very rough tokenizer-independent estimate. Good enough for session status;
   provider-reported usage below is authoritative for completed calls."
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
  (var n (approx-tokens agent.system-prompt))
  (each [_ msg (ipairs (or agent.messages []))]
    (set n (+ n (approx-tokens msg.role) (content-tokens msg.content)))
    (when (= msg.role :tool-result)
      (set n (+ n (approx-tokens msg.tool-name)))))
  n)

(fn usage-totals [messages]
  (let [u {:input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0}]
    (each [_ msg (ipairs (or messages []))]
      (when (and (= msg.role :assistant) msg.usage)
        (set u.input (+ u.input (or msg.usage.input 0)))
        (set u.output (+ u.output (or msg.usage.output 0)))
        (set u.cache-read (+ u.cache-read (or msg.usage.cache-read 0)))
        (set u.cache-write (+ u.cache-write (or msg.usage.cache-write 0)))
        (set u.total-tokens (+ u.total-tokens
                               (or msg.usage.total-tokens
                                   (+ (or msg.usage.input 0)
                                      (or msg.usage.output 0)))))))
    u))

(fn fmt-tokens [n]
  "Compact token formatter for /status. Presenter status rows may render
   their own live counters, but core commands derive their summary from
   core-owned agent messages and local context estimates."
  (let [n (or n 0)]
    (if (< n 1000) (tostring n)
        (< n 10000) (string.format "%.1fk" (/ n 1000))
        (< n 1000000) (string.format "%dk" (math.floor (/ n 1000)))
        (string.format "%.1fM" (/ n 1000000)))))

(fn format-token-summary [usage approx]
  "One-line token breakdown for /status with no presenter/TUI dependency."
  (.. "↑" (fmt-tokens usage.input)
      " ↓" (fmt-tokens usage.output)
      " R" (fmt-tokens usage.cache-read)
      " W" (fmt-tokens usage.cache-write)
      "  ctx:~" (fmt-tokens approx)))

(fn runtime-version []
  "Return the build-stamped version string, or unknown when running from
   source/tests without dist/version.lua."
  (let [(ok? v) (pcall require :version)]
    (if (and ok? v) (tostring v) "unknown")))

(fn format-auth [state]
  "Describe how the active provider is authenticating for the status row.
   Codex uses OAuth credentials from ~/.pi/agent/auth.json; built-in
   providers use env-var API keys; custom providers may have their own."
  (let [provider state.opts.provider]
    (if (= provider :openai-codex)
        "subscription (via pi)"
        (= provider :openai)
        "$OPENAI_API_KEY"
        (= provider :openai-responses)
        "$OPENAI_API_KEY"
        (= provider :anthropic)
        "$ANTHROPIC_API_KEY"
        (.. "custom (" (tostring provider) ")"))))

(fn format-status [state]
  (let [agent state.agent
        usage (usage-totals agent.messages)
        approx (estimated-context-tokens agent)
        session-path (if state.session state.session.path nil)]
    (.. "Status\n"
        "version: " (runtime-version) "\n"
        "model: " (tostring agent.model) "\n"
        "provider: " (tostring agent.provider-api) "\n"
        "auth: " (format-auth state) "\n"
        "messages: " (tostring (length (or agent.messages []))) "\n"
        "approx context: ~" (tostring approx) " tokens\n"
        "reported usage: " (tostring usage.total-tokens) " tokens"
        " (input " (tostring usage.input)
        ", output " (tostring usage.output)
        ", cache read " (tostring usage.cache-read)
        ", cache write " (tostring usage.cache-write) ")\n"
        "tokens: " (format-token-summary usage approx) "\n"
        "reply cap: " (tostring agent.max-tokens) " tokens\n"
        "session: " (or session-path "disabled") "\n"
        "note: approx context is estimated locally; reported usage comes from completed provider calls.")))

(fn nth-arg [args n]
  (let [pat (.. (string.rep "%S+%s+" (- n 1)) "(%S+)")]
    (string.match (or args "") pat)))

(fn first-arg [args]
  (nth-arg args 1))

;; -----------------------------------------------------------------
;; Registration
;; -----------------------------------------------------------------

;; The api is shared by all built-ins — they're all "owned" by core. On reload
;; this module re-registers everything; we drop the prior batch first so a
;; renamed/removed command doesn't leak.
(extensions.unregister-by-owner :core)
(local api (extensions.make-api :core))

(api.register :command
  {:name :status
   :description "Show model, provider, message count, and token usage"
   :handler (fn [_args state]
              (extensions.emit
                {:type :assistant-text
                 :text (format-status state)}))})

(api.register :command
  {:name :new
   :description "Reset the current conversation and start a fresh session"
   :idle-only? true
   :handler (fn [_args state]
              (session-mod.close state.session)
              (state.loader.reload state.loader)
              (set state.agent
                   (state.make-agent-from-opts
                     state.opts state.on-event state.loader state.agent-extra))
              (set state.steering-queue [])
              (set state.follow-up-queue [])
              (when state.update-queue-status (state.update-queue-status))
              (set state.session (state.open-session state.opts))
              (set state.flush (state.make-flush state.agent state.session))
              ;; Tell the active presenter to clear its transcript and
              ;; refresh the model/provider readout. Routed through the
              ;; bus so this handler stays presenter-agnostic.
              (extensions.emit {:type :reset-conversation})
              (extensions.emit
                {:type :set-status-info
                 :info {:provider state.opts.provider
                        :model state.agent.model}})
              (extensions.emit
                {:type :assistant-text
                 :text "✓ New session started"}))})

(api.register :command
  {:name :n
   :description "Alias for /new"
   :idle-only? true
   :handler (fn [args state]
              ;; Delegate to /new via the registry to avoid duplicating the
              ;; body. The dispatcher does not recurse for us so we look it up
              ;; ourselves — same handler, same semantics.
              ((. extensions.commands-extra :new :handler) args state))})

(api.register :command
  {:name :reload
   :description "Hot-reload core modules (run `make build` first)"
   :idle-only? true
   :handler (fn [_args state]
              (let [(n failures) (state.reload-modules)
                    _ (set state.loader (state.resource-loader.make state.opts))
                    saved state.agent.messages
                    new-agent (state.make-agent-from-opts
                                state.opts state.on-event state.loader
                                state.agent-extra)]
                ;; Reuse the messages table by reference so any code that still
                ;; holds the old agent's messages table sees appended messages.
                (set new-agent.messages saved)
                (set state.agent new-agent)
                ;; Re-apply presenter runtime config (input mode, cached
                ;; dims) — init! is idempotent so this is safe even if the
                ;; presenter is already initialized.
                (extensions.emit {:type :reinit-presenter})
                (extensions.emit
                  {:type :assistant-text
                   :text (.. "/reload — rebuilt agent from " (tostring n)
                             " modules; session preserved ("
                             (tostring (length saved)) " messages)")})
                (each [_ f (ipairs failures)]
                  (extensions.emit {:type :error :error (.. "reload: " f)}))
                ;; A reload often changes renderer/layout code; force a full
                ;; repaint instead of trusting any cached front-buffer diff.
                (extensions.emit {:type :redraw})))})

(api.register :command
  {:name :r
   :description "Alias for /reload"
   :idle-only? true
   :handler (fn [args state]
              ((. extensions.commands-extra :reload :handler) args state))})

;; /expand, /markdown, /thinking moved to extensions.tui in Step 3c
;; (issue #15) — they mutate tui-state directly and now register from
;; inside the TUI extension. Their /help entries below describe them
;; for users; the registration lives there.

(api.register :command
  {:name :queue
   :description "Show or clear queued steering/follow-up messages"
   :handler (fn [args state]
              (let [arg1 (first-arg args)
                    arg2 (nth-arg args 2)
                    arg3 (nth-arg args 3)]
                (if (= arg1 :clear)
                    (do
                      (when (or (= arg2 nil) (= arg2 :steering) (= arg2 :all))
                        (set state.steering-queue []))
                      (when (or (= arg2 nil) (= arg2 :follow-up)
                                (= arg2 :followup) (= arg2 :all))
                        (set state.follow-up-queue []))
                      (when state.update-queue-status (state.update-queue-status))
                      (extensions.emit {:type :info :text "queue cleared"}))
                    (= arg1 :mode)
                    (let [which arg2
                          mode arg3]
                      (if (and (or (= mode :one-at-a-time) (= mode :all))
                               (or (= which :steering) (= which :follow-up)
                                   (= which :followup)))
                          (do
                            (if (= which :steering)
                                (set state.steering-mode mode)
                                (set state.follow-up-mode mode))
                            (extensions.emit
                              {:type :info
                               :text (.. "queue mode " (tostring which)
                                         " = " (tostring mode))}))
                          (extensions.emit
                            {:type :error
                             :error "usage: /queue mode steering|follow-up one-at-a-time|all"})))
                    (let [lines ["Queue"
                                 (.. "steering ("
                                     (tostring (length (or state.steering-queue [])))
                                     ", " (tostring state.steering-mode) ")")]]
                      (var n 0)
                      (each [_ v (ipairs (or state.steering-queue []))]
                        (set n (+ n 1))
                        (table.insert lines (.. "  " (tostring n) ". " v)))
                      (table.insert lines
                                    (.. "follow-up ("
                                        (tostring (length (or state.follow-up-queue [])))
                                        ", " (tostring state.follow-up-mode) ")"))
                      (set n 0)
                      (each [_ v (ipairs (or state.follow-up-queue []))]
                        (set n (+ n 1))
                        (table.insert lines (.. "  " (tostring n) ". " v)))
                      (table.insert lines "commands: /queue clear [steering|follow-up|all], /queue mode steering|follow-up one-at-a-time|all")
                      (extensions.emit {:type :assistant-text
                                        :text (table.concat lines "\n")})))))})

(api.register :command
  {:name :cancel-all
   :description "Cancel current turn and clear queues"
   :handler (fn [_args state]
              (when state.busy? (set state.cancel-requested? true))
              (set state.steering-queue [])
              (set state.follow-up-queue [])
              (when state.update-queue-status (state.update-queue-status))
              (extensions.emit
                {:type :info
                 :text "cancel requested; queues cleared"}))})

(local HELP-TEXT
  (.. "\n"
      "/new            reset the current conversation\n"
      "/reload         hot-reload core modules (run `make build` first)\n"
      "/status         show model, provider, message count, and token usage\n"
      "/queue          show/clear queued steering and follow-up messages\n"
      "/cancel-all     cancel current turn and clear queues\n"
      "/expand [on|off] toggle full tool-result bodies (default: collapsed)\n"
      "/markdown [on|off] toggle Markdown rendering of assistant text\n"
      "/thinking [on|off] show or hide thinking blocks (default: visible)\n"
      "/help           this list\n"
      "ctrl-o          toggle tool-result bodies\n"
      "ctrl-t          toggle thinking blocks\n"
      "ctrl-c / ctrl-d to quit"))

(api.register :command
  {:name :help
   :description "Show available commands"
   :handler (fn [_args _state]
              (extensions.emit {:type :assistant-text :text HELP-TEXT}))})

M
