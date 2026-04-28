;; Built-in slash commands.
;;
;; Each command registers via `(api.register :command {...})` against the
;; shared extension api at module load time. The `core.commands` dispatcher
;; (now a thin lookup) delegates to whatever's been registered. Loading this
;; module is a side-effect-only operation — `require`ing it triggers the
;; registrations.
;;
;; Handlers receive `(args state)` where `args` is the substring after the
;; command name and `state` is the run-interactive state record.
;;
;; Transitional note (issue #15, Step 2 of v1 build order): a handful of
;; handlers still need to touch the TUI module directly (/new resets the
;; conversation, /reload re-initializes termbox, /expand/markdown/thinking
;; toggle TUI-internal flags). Those reach for `tui.tui` and `tui.state`
;; via lazy `require` inside the handler body, *not* at module load time —
;; killing the top-level imports that previously lived at `commands.fnl:8-10`
;; is the layering improvement Step 2 buys. Step 3 moves the TUI under
;; `src/extensions/` and lets it register its own TUI-coupled commands;
;; the lazy requires here go away then.

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
  "Compact token formatter shared with the TUI status row."
  (let [n (or n 0)]
    (if (< n 1000) (tostring n)
        (< n 10000) (string.format "%.1fk" (/ n 1000))
        (< n 1000000) (string.format "%dk" (math.floor (/ n 1000)))
        (string.format "%.1fM" (/ n 1000000)))))

(fn format-token-summary []
  "One-line cumulative token breakdown — the columns previously inlined
   in the status row (↑input ↓output Rcache Wcache ctx). Pulls from the
   TUI's status-info, which is the authoritative running tally."
  (let [tui-state (require :tui.state)
        s tui-state.status-info]
    (.. "↑" (fmt-tokens s.cum-input)
        " ↓" (fmt-tokens s.cum-output)
        " R" (fmt-tokens s.cum-cache-read)
        " W" (fmt-tokens s.cum-cache-write)
        "  ctx:" (fmt-tokens s.last-input))))

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
        "tokens: " (format-token-summary) "\n"
        "reply cap: " (tostring agent.max-tokens) " tokens\n"
        "session: " (or session-path "disabled") "\n"
        "note: approx context is estimated locally; reported usage comes from completed provider calls.")))

(fn first-arg [args]
  (string.match (or args "") "^(%S+)"))

(fn nth-arg [args n]
  (let [pat (.. (string.rep "%S+%s+" (- n 1)) "(%S+)")]
    (string.match (or args "") pat)))

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
              (let [tui (require :tui.tui)]
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
                (tui.reset-conversation!)
                (tui.set-status-info {:provider state.opts.provider
                                      :model state.agent.model})
                (extensions.emit
                  {:type :assistant-text
                   :text "✓ New session started"})))})

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
              (let [tui (require :tui.tui)
                    (n failures) (state.reload-modules)
                    _ (set state.loader (state.resource-loader.make state.opts))
                    saved state.agent.messages
                    new-agent (state.make-agent-from-opts
                                state.opts state.on-event state.loader
                                state.agent-extra)]
                ;; Reuse the messages table by reference so any code that still
                ;; holds the old agent's messages table sees appended messages.
                (set new-agent.messages saved)
                (set state.agent new-agent)
                ;; Re-apply TUI runtime config (input mode, cached dims) so
                ;; tui.fnl edits to init-time settings pick up without a
                ;; restart. init! is idempotent: it won't re-run tb_init when
                ;; already initialized.
                (tui.init!)
                (extensions.emit
                  {:type :assistant-text
                   :text (.. "/reload — rebuilt agent from " (tostring n)
                             " modules; session preserved ("
                             (tostring (length saved)) " messages)")})
                (each [_ f (ipairs failures)]
                  (extensions.emit {:type :error :error (.. "reload: " f)}))
                ;; A reload often changes renderer/layout code; force a full
                ;; repaint instead of trusting termbox2's cached front-buffer
                ;; diff.
                (tui.force-redraw!)))})

(api.register :command
  {:name :r
   :description "Alias for /reload"
   :idle-only? true
   :handler (fn [args state]
              ((. extensions.commands-extra :reload :handler) args state))})

(api.register :command
  {:name :expand
   :description "Toggle full vs collapsed tool-result bodies"
   :handler (fn [args _state]
              (let [tui-state (require :tui.state)
                    arg (first-arg args)
                    new-val (if (= arg :on) true
                                (= arg :off) false
                                (not tui-state.expand-tool-results?))]
                (set tui-state.expand-tool-results? new-val)
                (extensions.emit
                  {:type :info
                   :text (.. "tool results: "
                             (if new-val "expanded" "collapsed"))})))})

(api.register :command
  {:name :markdown
   :description "Toggle Markdown rendering of assistant text"
   :handler (fn [args _state]
              (let [tui (require :tui.tui)
                    tui-state (require :tui.state)
                    arg (first-arg args)
                    new-val (if (= arg :on) true
                                (= arg :off) false
                                (not tui-state.markdown?))]
                (set tui-state.markdown? new-val)
                (extensions.emit
                  {:type :info
                   :text (.. "markdown rendering: "
                             (if new-val "on" "off"))})
                (tui.redraw!)))})

(api.register :command
  {:name :thinking
   :description "Show or hide assistant thinking blocks"
   :handler (fn [args _state]
              (let [tui (require :tui.tui)
                    tui-state (require :tui.state)
                    arg (first-arg args)
                    ;; User-facing wording is visibility, while state stores
                    ;; hiding.
                    visible? (if (= arg :on) true
                                 (= arg :off) false
                                 tui-state.hide-thinking-block?)
                    hide? (not visible?)]
                (set tui-state.hide-thinking-block? hide?)
                (extensions.emit
                  {:type :info
                   :text (.. "thinking blocks: "
                             (if hide? "hidden" "visible"))})
                (tui.redraw!)))})

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
