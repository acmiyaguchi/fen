;; Interactive slash command dispatcher.
;;
;; This module is intentionally separate from main.fnl so /reload can mutate
;; its module table in place. The interactive loop calls `commands.handle` via
;; the module table each time, so newly compiled command logic is picked up on
;; the next slash command without restarting the process.

(local session-mod (require :core.session))
(local json (require :util.json))
(local tui-state (require :tui.state))

(local M {})

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
  (let [s tui-state.status-info]
    (.. "↑" (fmt-tokens s.cum-input)
        " ↓" (fmt-tokens s.cum-output)
        " R" (fmt-tokens s.cum-cache-read)
        " W" (fmt-tokens s.cum-cache-write)
        "  ctx:" (fmt-tokens s.last-input))))

(fn format-status [state]
  (let [agent state.agent
        usage (usage-totals agent.messages)
        approx (estimated-context-tokens agent)
        session-path (if state.session state.session.path nil)]
    (.. "Status\n"
        "model: " (tostring agent.model) "\n"
        "provider: " (tostring agent.provider-api) "\n"
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

(fn M.handle [line state]
  "Dispatch a `/`-prefixed slash command. Returns true if the line was a
   command (handled or rejected), so the caller can skip agent.step."
  (let [tui (require :tui.tui)
        cmd (string.match line "^/(%S+)")
        mutating? (or (= cmd :new) (= cmd :n)
                      (= cmd :reload) (= cmd :r))]
    (if (and state.busy? mutating?)
        (tui.append-event
          {:type :error
           :error (.. "/" (tostring cmd)
                      " is disabled while the agent is running")})
        (or (= cmd :new) (= cmd :n))
        (do
          (session-mod.close state.session)
          (set state.agent
               (state.make-agent-from-opts
                 state.opts state.on-event state.skills))
          (set state.session (state.open-session state.opts))
          (set state.flush (state.make-flush state.agent state.session))
          (tui.reset-conversation!)
          (tui.set-status-info {:provider state.opts.provider
                                :model state.agent.model})
          (tui.append-event
            {:type :assistant-text
             :text "✓ New session started"}))
        (or (= cmd :reload) (= cmd :r))
        (let [(n failures) (state.reload-modules)
              saved state.agent.messages
              new-agent (state.make-agent-from-opts
                          state.opts state.on-event state.skills)]
          ;; Reuse the messages table by reference so any code that still
          ;; holds the old agent's messages table sees appended messages.
          (set new-agent.messages saved)
          (set state.agent new-agent)
          ;; Re-apply TUI runtime config (input mode, cached dims) so tui.fnl
          ;; edits to init-time settings pick up without a restart. init! is
          ;; idempotent: it won't re-run tb_init when already initialized.
          (tui.init!)
          (tui.append-event
            {:type :assistant-text
             :text (.. "/reload — rebuilt agent from " (tostring n)
                       " modules; session preserved ("
                       (tostring (length saved)) " messages)")})
          (each [_ f (ipairs failures)]
            (tui.append-event {:type :error :error (.. "reload: " f)})))
        (= cmd :status)
        (tui.append-event
          {:type :assistant-text
           :text (format-status state)})
        (= cmd :expand)
        (let [arg (string.match line "^/%S+%s+(%S+)")
              new-val (if (= arg :on) true
                          (= arg :off) false
                          (not tui-state.expand-tool-results?))]
          (set tui-state.expand-tool-results? new-val)
          (tui.append-event
            {:type :info
             :text (.. "tool results: "
                       (if new-val "expanded" "collapsed"))}))
        (= cmd :help)
        (tui.append-event
          {:type :assistant-text
           :text (.. "\n"
                     "/new            reset the current conversation\n"
                     "/reload         hot-reload core modules (run `make build` first)\n"
                     "/status         show model, provider, message count, and token usage\n"
                     "/expand [on|off] toggle full tool-result bodies (default: collapsed)\n"
                     "/help           this list\n"
                     "ctrl-c / ctrl-d to quit")})
        (tui.append-event
          {:type :error
           :error (.. "unknown command: /" (tostring cmd) " (try /help)")}))))

M
