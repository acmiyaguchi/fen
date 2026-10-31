;; #620: after compaction the kept assistant message still carries usage that
;; describes the pre-compaction context, so `context-token-info` reports that
;; old size as exact (provider-reported) while compaction's own hint says the
;; context is now a few dozen tokens.

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
    (events.on :* (fn [ev] (table.insert seen ev)) :issue-620-test)
    (compact.register api)
    (let [before (tokens.usage-totals state.agent.messages)]
      (command-registry.dispatch "/compact" state)
      (while (and state.turn (not= :dead (coroutine.status state.turn)))
        (assert (coroutine.resume state.turn)))
      (values state seen before))))

(describe "#620 context size after compaction"
          (fn []
            (after_each (fn []
                          (test-api.reset!)
                          (tset package.loaded :fen.extensions.compact nil)
                          (tset package.loaded :fen.core.agent
                                original-agent-mod)))
            (it "reports the pre-compaction size as provider-reported"
                (fn []
                  (known-bug 620
                             (fn []
                               (let [(state seen) (run-compact!)
                                     ctx (tokens.context-token-info state.agent)
                                     hint (accumulate [h nil _ ev (ipairs seen)]
                                            (if (= ev.type :set-status-info)
                                                ev.info.approx-context
                                                h))
                                     estimate (tokens.estimated-context-tokens state.agent)]
                                 (and (= 3 (length state.agent.messages))
                                      (= 44650 ctx.tokens)
                                      (= :provider-reported ctx.source)
                                      (= false ctx.estimated?) (< hint 1000)
                                      (< estimate 1000)))))))))
