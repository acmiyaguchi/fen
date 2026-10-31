;; #620: after compaction the kept assistant message still carries usage that
;; describes the pre-compaction context, so `context-token-info` reports that
;; old size as exact (provider-reported) while compaction's own hint says the
;; context is now a few dozen tokens.

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))
(local types (require :fen.core.types))
(local tokens (require :fen.util.tokens))
(local ledger (require :fen.core.extensions.usage_ledger))

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
    ;; The turns' usage was reported live before /compact ran.
    (each [_ m (ipairs state.agent.messages)]
      (when m.usage (ledger.record! m.usage {:session :s})))
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
            (it "falls back to the estimate instead of the pre-compaction provider size"
                (fn []
                  ;; The kept assistant message was reported live before the rewrite.
                  (let [(state seen) (run-compact!)
                        ctx (ledger.context-info state.agent)
                        estimate (tokens.estimated-context-tokens state.agent)]
                    (assert.are.equal 3 (length state.agent.messages))
                    (assert.are.equal :estimated ctx.source)
                    (assert.is_true ctx.estimated?)
                    (assert.is_true (< ctx.tokens 1000))
                    (assert.is_true (< estimate 1000)))))))
