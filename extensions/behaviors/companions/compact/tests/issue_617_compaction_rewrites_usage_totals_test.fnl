;; #617: session usage is summed over agent.messages, and compaction replaces
;; them, so `/status` reported usage drops; the summary call's usage goes out
;; only as :llm-end and is in no message-derived total.

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))
(local types (require :fen.core.types))
(local tokens (require :fen.util.tokens))
(local {: known-bug} (require :fen.testing))

(local original-agent-mod (. package.loaded :fen.core.agent))

(fn with-id [msg id]
  (tset msg :__session-entry-id id)
  msg)

(fn asst [text usage]
  (types.assistant-message {:api :test
                            :provider :test
                            :model "m"
                            :content [(types.text-block text)]
                            : usage
                            :stop-reason :stop}))

(fn usage [input output cache-read]
  {: input : output : cache-read :cache-write 0 :total-tokens (+ input output)})

(fn run-compact! []
  "Real /compact over a four-message history; the summary call is stubbed
   with input 30000. Returns the run state and every bus event."
  (test-api.reset!)
  (tset package.loaded :fen.extensions.compact nil)
  (tset package.loaded :fen.core.agent
        {:complete-messages (fn [] (asst "summary" (usage 30000 10 0)))})
  (let [seen []
        api (test-api.make-runtime-api :compact {:name :compact})
        compact (require :fen.extensions.compact)
        big (string.rep "x" 90000)
        state {:agent {:model "m"
                       :messages [(with-id (types.user-message big) "m1")
                                  (with-id (asst big (usage 22000 50 0)) "m2")
                                  (with-id (types.user-message "recent") "m3")
                                  (with-id (asst "recent" (usage 100 50 44500))
                                    "m4")]}
               :session {:id :s}
               :session-backend {:append-entry (fn [_ entry]
                                                 (let [out {:id "comp-1"}]
                                                   (each [k v (pairs entry)]
                                                     (tset out k v))
                                                   out))}
               :flush (fn [] nil)
               :make-flush (fn [] (fn [] nil))
               :busy? false
               :turn-id 1
               :cancel-requested? false}]
    (set api.settings {:extension (fn [] {})})
    (events.on :* (fn [ev] (table.insert seen ev)) :issue-617-test)
    (compact.register api)
    (let [before (tokens.usage-totals state.agent.messages)]
      (command-registry.dispatch "/compact" state)
      (while (and state.turn (not= :dead (coroutine.status state.turn)))
        (assert (coroutine.resume state.turn)))
      (values state seen before))))

(describe "#617 compaction and session usage"
          (fn []
            (after_each (fn []
                          (test-api.reset!)
                          (tset package.loaded :fen.extensions.compact nil)
                          (tset package.loaded :fen.core.agent
                                original-agent-mod)))
            (it "drops summarized usage and omits the summary call"
                (fn []
                  (known-bug 617
                             (fn []
                               (let [(state seen before) (run-compact!)
                                     after (tokens.usage-totals state.agent.messages)
                                     bus-input (accumulate [n 0 _ ev (ipairs seen)]
                                                 (if (and (= ev.type :llm-end)
                                                          ev.usage)
                                                     (+ n ev.usage.input)
                                                     n))]
                                 (and (= 3 (length state.agent.messages))
                                      (= 22100 before.input) (= 100 after.input)
                                      (= 30000 bus-input)))))))))
