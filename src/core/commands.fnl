;; Interactive slash command dispatcher.
;;
;; This module is intentionally separate from main.fnl so /reload can mutate
;; its module table in place. The interactive loop calls `commands.handle` via
;; the module table each time, so newly compiled command logic is picked up on
;; the next slash command without restarting the process.

(local session-mod (require :core.session))
(local json (require :util.json))

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
        "reply cap: " (tostring agent.max-tokens) " tokens\n"
        "session: " (or session-path "disabled") "\n"
        "note: approx context is estimated locally; reported usage comes from completed provider calls.")))

(fn M.handle [line state]
  "Dispatch a `/`-prefixed slash command. Returns true if the line was a
   command (handled or rejected), so the caller can skip agent.step."
  (let [tui (require :tui.tui)
        cmd (string.match line "^/(%S+)")]
    (if (or (= cmd :new) (= cmd :n))
        (do
          (session-mod.close state.session)
          (set state.agent.messages [])
          (set state.session (state.open-session state.opts))
          (set state.flush (state.make-flush state.agent state.session))
          (tui.append-event
            {:type :assistant-text
             :text "/new — started a fresh conversation"}))
        (or (= cmd :reload) (= cmd :r))
        (let [(n failures) (state.reload-modules)
              saved state.agent.messages
              new-agent (state.make-agent-from-opts
                          state.opts state.api-key state.on-event state.skills)]
          ;; Reuse the messages table by reference so any code that still
          ;; holds the old agent's messages table sees appended messages.
          (set new-agent.messages saved)
          (set state.agent new-agent)
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
        (= cmd :help)
        (tui.append-event
          {:type :assistant-text
           :text (.. "/new      reset the current conversation\n"
                     "/reload   hot-reload core modules (run `make build` first)\n"
                     "/status   show model, provider, message count, and token usage\n"
                     "/help     this list\n"
                     "ctrl-c / ctrl-d to quit")})
        (tui.append-event
          {:type :error
           :error (.. "unknown command: /" (tostring cmd) " (try /help)")}))))

M
