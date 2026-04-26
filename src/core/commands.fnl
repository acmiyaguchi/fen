;; Interactive slash command dispatcher.
;;
;; This module is intentionally separate from main.fnl so /reload can mutate
;; its module table in place. The interactive loop calls `commands.handle` via
;; the module table each time, so newly compiled command logic is picked up on
;; the next slash command without restarting the process.

(local session-mod (require :core.session))

(local M {})

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
        (= cmd :help)
        (tui.append-event
          {:type :assistant-text
           :text (.. "/new      reset the current conversation\n"
                     "/reload   hot-reload core modules (run `make build` first)\n"
                     "/help     this list\n"
                     "ctrl-c / ctrl-d to quit")})
        (tui.append-event
          {:type :error
           :error (.. "unknown command: /" (tostring cmd) " (try /help)")}))))

M
