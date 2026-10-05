(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))
(local tool-registry (require :fen.core.extensions.register.tool))
(local types (require :fen.core.types))

(local original-agent-mod (. package.loaded :fen.core.agent))
(local original-decide-service
       (. package.loaded :fen.extensions.decide.service))

(local original-decide-compaction
       (. package.loaded :fen.extensions.decide.compaction))

(fn restore-modules! []
  (tset package.loaded :fen.extensions.compact nil)
  (tset package.loaded :fen.core.agent original-agent-mod)
  (tset package.loaded :fen.extensions.decide.service original-decide-service)
  (tset package.loaded :fen.extensions.decide.compaction
        original-decide-compaction))

(fn event-count [seen type-key]
  (var n 0)
  (each [_ ev (ipairs seen)]
    (when (= ev.type type-key)
      (set n (+ n 1))))
  n)

(fn last-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (= ev.type type-key)
      (set found ev)))
  found)

(fn make-assistant [text]
  (types.assistant-message {:api :test
                            :provider :test
                            :model "test-model"
                            :content [(types.text-block text)]
                            :usage {:input 9
                                    :output 5
                                    :cache-read 0
                                    :cache-write 0
                                    :total-tokens 14}
                            :stop-reason :stop}))

(fn with-id [msg id]
  (tset msg :__session-entry-id id)
  msg)

(fn fresh [complete-messages ?decide-compaction ?settings]
  (test-api.reset!)
  (tset package.loaded :fen.extensions.compact nil)
  (tset package.loaded :fen.core.agent {:complete-messages complete-messages})
  (when ?decide-compaction
    (tset package.loaded :fen.extensions.decide.compaction ?decide-compaction))
  (let [seen []
        api (test-api.make-runtime-api :compact {:name :compact})
        compact (require :fen.extensions.compact)]
    (set api.settings {:extension (fn [] (or ?settings {}))})
    (events.on :* (fn [ev] (table.insert seen ev)) :compact-test)
    (compact.register api)
    (values seen compact)))

(fn registered-tool [name]
  (var found nil)
  (each [_ tool (ipairs (tool-registry.merged []))]
    (when (= tool.name name)
      (set found tool)))
  found)

(fn first-result-text [result]
  (?. result :content 1 :text))

(fn large-text []
  (string.rep "x" 90000))

(fn make-state []
  (let [entries []
        flushes {:n 0}
        backend {:append-entry (fn [_session entry]
                                 (let [out {}]
                                   (each [k v (pairs entry)]
                                     (tset out k v))
                                   (set out.id
                                        (or out.id
                                            (.. "comp-" (+ (length entries) 1))))
                                   (table.insert entries out)
                                   out))}
        messages [(with-id (types.user-message (large-text)) "m1")
                  (with-id (types.assistant-message {:api :test
                                                     :provider :test
                                                     :model "m"
                                                     :content [(types.text-block (large-text))]
                                                     :stop-reason :stop})
                    "m2")
                  (with-id (types.user-message "recent user") "m3")
                  (with-id (types.assistant-message {:api :test
                                                     :provider :test
                                                     :model "m"
                                                     :content [(types.text-block "recent assistant")]
                                                     :stop-reason :stop})
                    "m4")]]
    {:agent {:messages messages :model "m"}
     :session {:id :s}
     :session-backend backend
     :flush (fn [] (set flushes.n (+ flushes.n 1)))
     :make-flush (fn [_agent _session last-saved]
                   (set flushes.last-saved last-saved)
                   (fn [] nil))
     :busy? false
     :turn nil
     :turn-id 1
     :cancel-requested? false
     :_test {:entries entries :flushes flushes :original messages}}))

(describe "extensions.compact"
          (fn []
            (after_each restore-modules!)
            (it "/compact schedules cooperative work instead of blocking dispatch"
                (fn []
                  (let [called {:value false}
                        completed {:value false}
                        seen (fresh (fn [_agent
                                         _messages
                                         _model
                                         _opts
                                         _on-event
                                         yield-fn]
                                      (set called.value true)
                                      (assert.is_not_nil yield-fn)
                                      (yield-fn)
                                      (set completed.value true)
                                      (make-assistant "summary text")))
                        state (make-state)]
                    (command-registry.dispatch "/compact" state)
                    (assert.is_true state.busy?)
                    (assert.is_not_nil state.turn)
                    (assert.is_false called.value)
                    (let [(ok? err) (coroutine.resume state.turn)]
                      (assert.is_true ok? err))
                    (assert.is_true called.value)
                    (assert.is_false completed.value)
                    (assert.are.equal :suspended (coroutine.status state.turn))
                    (assert.are.equal 1 (event-count seen :llm-start)))))
            (it "compacts older messages, keeps recent messages, and writes a compaction entry"
                (fn []
                  (let [seen (fresh (fn [_agent
                                         _messages
                                         _model
                                         _opts
                                         _on-event
                                         yield-fn]
                                      (yield-fn)
                                      (make-assistant "summary text")))
                        state (make-state)]
                    (command-registry.dispatch "/compact focus files" state)
                    (let [(ok1? err1) (coroutine.resume state.turn)]
                      (assert.is_true ok1? err1))
                    (let [(ok2? err2) (coroutine.resume state.turn)]
                      (assert.is_true ok2? err2))
                    (assert.are.equal :dead (coroutine.status state.turn))
                    (assert.are.equal 3 (length state.agent.messages))
                    (assert.is_not_nil (string.find (. state.agent.messages 1
                                                       :content)
                                                    "summary text" 1 true))
                    (assert.are.equal "recent user"
                                      (. state.agent.messages 2 :content))
                    (assert.are.equal "recent assistant"
                                      (. state.agent.messages 3 :content 1
                                         :text))
                    (assert.are.equal 1 (length state._test.entries))
                    (let [entry (. state._test.entries 1)]
                      (assert.are.equal :compaction entry.type)
                      (assert.are.equal "m3" (. entry :first-kept-entry-id))
                      (assert.are.equal "focus files" entry.guidance))
                    (assert.are.equal 1 state._test.flushes.n)
                    (assert.are.equal 3 state._test.flushes.last-saved)
                    (assert.are.equal 1 (event-count seen :llm-end))
                    (let [done (last-event seen :compaction-summary)]
                      (assert.are.equal "summary text" done.summary)
                      (assert.are.equal 2 done.messages-summarized)
                      (assert.are.equal 2 done.messages-kept)
                      (assert.are.equal "focus files" done.guidance)
                      (assert.are.equal :manual done.trigger)))))
            (it "registers an agent-callable compact tool that persists compaction"
                (fn []
                  (let [seen (fresh (fn [_agent
                                         _messages
                                         _model
                                         _opts
                                         _on-event
                                         yield-fn]
                                      (yield-fn)
                                      (make-assistant "tool summary")))
                        state (make-state)
                        tool (registered-tool :compact)]
                    (table.insert state.agent.messages
                                  (with-id (types.user-message "compact before continuing")
                                    "m5"))
                    (table.insert state.agent.messages
                                  (with-id (types.assistant-message {:api :test
                                                                     :provider :test
                                                                     :model "m"
                                                                     :content [(types.tool-call-block "tc1"
                                                                                                      :compact
                                                                                                      {:guidance "preserve goal progress"})]
                                                                     :stop-reason :tool-use})
                                    "m6"))
                    (let [result (tool.execute {:guidance "preserve goal progress"}
                                               {:state state} (fn [] nil))]
                      (assert.is_not_nil tool)
                      (assert.is_false result.is-error?)
                      (assert.is_truthy (string.find (first-result-text result)
                                                     "Compacted context" 1 true))
                      (assert.are.equal :tool-call
                                        (. state.agent.messages 5 :content 1
                                           :type))
                      (assert.are.equal "tc1"
                                        (. state.agent.messages 5 :content 1
                                           :id))
                      (assert.are.equal 1 (length state._test.entries))
                      (let [entry (. state._test.entries 1)
                            done (last-event seen :compaction-summary)]
                        (assert.are.equal :agent entry.trigger)
                        (assert.are.equal "preserve goal progress"
                                          entry.guidance)
                        (assert.are.equal :agent done.trigger)
                        (assert.are.equal "tool summary" done.summary))))))
            (it "does not persist or install a provider-error summary"
                (fn []
                  (let [seen (fresh (fn []
                                      (types.assistant-message {:api :test
                                                                :provider :test
                                                                :model "m"
                                                                :content [(types.text-block "[error] upstream failed")]
                                                                :error-message "upstream failed"
                                                                :stop-reason :error})))
                        state (make-state)
                        original [(table.unpack state.agent.messages)]
                        tool (registered-tool :compact)
                        result (tool.execute {} {:state state} (fn [] nil))]
                    (assert.is_true result.is-error?)
                    (assert.is_truthy (string.find (first-result-text result)
                                                   "upstream failed" 1 true))
                    (assert.are.equal 0 (length state._test.entries))
                    (assert.are.equal (length original)
                                      (length state.agent.messages))
                    (assert.are.equal 1 (event-count seen :llm-start))
                    (assert.are.equal 1 (event-count seen :llm-end)))))
            (it "returns a tool error when context cannot be compacted"
                (fn []
                  (let [(seen _compact) (fresh (fn [] (make-assistant "unused")))
                        state (make-state)
                        tool (registered-tool :compact)]
                    (set state.agent.messages
                         [(with-id (types.user-message "small") "m1")])
                    (let [result (tool.execute {} {:state state} (fn [] nil))]
                      (assert.is_true result.is-error?)
                      (assert.is_truthy (string.find (first-result-text result)
                                                     "not enough context" 1 true))
                      (assert.are.equal 0 (event-count seen :error))))))
            (it "propagates agent-tool cancellation to the agent loop"
                (fn []
                  (let [seen (fresh (fn [_agent
                                         _messages
                                         _model
                                         _opts
                                         _on-event
                                         yield-fn]
                                      (yield-fn)
                                      (make-assistant "should not install")))
                        state (make-state)
                        original [(table.unpack state.agent.messages)]
                        tool (registered-tool :compact)
                        cancel-marker {:type :test-cancel}
                        (ok? err) (pcall tool.execute {} {:state state}
                                         (fn [] (error cancel-marker)))]
                    (assert.is_false ok?)
                    (assert.are.equal cancel-marker err)
                    (assert.are.equal (length original)
                                      (length state.agent.messages))
                    (assert.are.equal 0 (length state._test.entries))
                    (assert.are.equal 1 (event-count seen :llm-start))
                    (assert.are.equal 1 (event-count seen :llm-end)))))
            (it "cancels without mutating messages or writing entries"
                (fn []
                  (let [seen (fresh (fn [_agent
                                         _messages
                                         _model
                                         _opts
                                         _on-event
                                         yield-fn]
                                      (yield-fn)
                                      (make-assistant "should not install")))
                        state (make-state)
                        original [(table.unpack state.agent.messages)]]
                    (command-registry.dispatch "/compact" state)
                    (let [(ok1? err1) (coroutine.resume state.turn)]
                      (assert.is_true ok1? err1))
                    (set state.cancel-requested? true)
                    (let [(ok2? err2) (coroutine.resume state.turn)]
                      (assert.is_true ok2? err2))
                    (assert.are.equal :dead (coroutine.status state.turn))
                    (assert.are.equal (length original)
                                      (length state.agent.messages))
                    (each [i msg (ipairs original)]
                      (assert.are.equal msg (. state.agent.messages i)))
                    (assert.are.equal 0 (length state._test.entries))
                    (assert.are.equal 1 (event-count seen :cancelled)))))
            (it "does not call the model when there is not enough context"
                (fn []
                  (let [called {:value false}
                        seen (fresh (fn [_agent
                                         _messages
                                         _model
                                         _opts
                                         _on-event
                                         _yield-fn]
                                      (set called.value true)
                                      (make-assistant "unused")))
                        state (make-state)]
                    (set state.agent.messages
                         [(with-id (types.user-message "small") "m1")
                          (with-id (types.assistant-message {:api :test
                                                             :provider :test
                                                             :model "m"
                                                             :content [(types.text-block "small")]
                                                             :stop-reason :stop})
                            "m2")])
                    (command-registry.dispatch "/compact" state)
                    (let [(ok? err) (coroutine.resume state.turn)]
                      (assert.is_true ok? err))
                    (assert.is_false called.value)
                    (assert.are.equal 0 state._test.flushes.n)
                    (assert.are.equal 0 (length state._test.entries))
                    (let [err (last-event seen :error)]
                      (assert.is_not_nil (string.find err.error
                                                      "not enough context" 1
                                                      true))))))
            (it "does not flush when the session backend cannot persist compactions"
                (fn []
                  (let [called {:value false}
                        seen (fresh (fn [_agent
                                         _messages
                                         _model
                                         _opts
                                         _on-event
                                         _yield-fn]
                                      (set called.value true)
                                      (make-assistant "unused")))
                        state (make-state)]
                    (set state.session-backend {})
                    (command-registry.dispatch "/compact" state)
                    (let [(ok? err) (coroutine.resume state.turn)]
                      (assert.is_true ok? err))
                    (assert.is_false called.value)
                    (assert.are.equal 0 state._test.flushes.n)
                    (let [err (last-event seen :error)]
                      (assert.is_not_nil (string.find err.error "append%-entry"))))))
            (it "cut finder refuses assistant thinking at the kept boundary"
                (fn []
                  (let [(_seen compact) (fresh (fn [] (make-assistant "unused")))
                        msgs [(with-id (types.user-message (large-text)) "m1")
                              (with-id (types.assistant-message {:api :test
                                                                 :provider :test
                                                                 :model "m"
                                                                 :content [(types.thinking-block {:thinking (large-text)
                                                                                                  :thinking-signature "sig"})]
                                                                 :stop-reason :stop})
                                "m2")]]
                    (assert.is_nil (compact._test.find-cut-point msgs 20000)))))))

;; ----------------------------------------------------------------
;; The decide.compaction call sites, mocked (#512, #511, #571)
;; ----------------------------------------------------------------

(fn tool-state []
  "Older span: a large user turn, a `read` result, and a `bash` result; the
   kept span starts at `recent user`."
  (let [state (make-state)
        read-out (.. "READ-HEAD " (string.rep "r" 4000) " READ-TAIL")
        bash-out (.. "BASH-HEAD " (string.rep "b" 4000) " BASH-TAIL")
        tiny-out "tiny"]
    (set state.agent.messages [(with-id (types.user-message (large-text)) "m1")
                               (with-id (types.assistant-message {:api :test
                                                                  :provider :test
                                                                  :model "m"
                                                                  :content [(types.tool-call-block "tc1"
                                                                                                   :read
                                                                                                   {:path "src/a.fnl"})
                                                                            (types.tool-call-block "tc2"
                                                                                                   :bash
                                                                                                   {:command "make test"})
                                                                            (types.tool-call-block "tc3"
                                                                                                   :ls
                                                                                                   {})]
                                                                  :stop-reason :tool-use})
                                 "m2")
                               (with-id (types.tool-result-message {:tool-call-id "tc1"
                                                                    :tool-name :read
                                                                    :content [(types.text-block read-out)]})
                                 "m3")
                               (with-id (types.tool-result-message {:tool-call-id "tc2"
                                                                    :tool-name :bash
                                                                    :content [(types.text-block bash-out)]})
                                 "m4")
                               (with-id (types.tool-result-message {:tool-call-id "tc3"
                                                                    :tool-name :ls
                                                                    :content [(types.text-block tiny-out)]})
                                 "m5")
                               (with-id (types.user-message "recent user: fix the failing test")
                                 "m6")
                               (with-id (types.assistant-message {:api :test
                                                                  :provider :test
                                                                  :model "m"
                                                                  :content [(types.text-block "recent assistant")]
                                                                  :stop-reason :stop})
                                 "m7")])
    (set state._test.original [(table.unpack state.agent.messages)])
    state))

(fn mock-decide-compaction [?rate]
  "decide.compaction stub: rate-tool-results answers through ?rate (default:
   the span unchanged); ask-good-moment! records requests so tests call
   on-good by hand."
  (let [rates []
        asks []]
    (values {:rate-tool-results (fn [messages span ?yield!]
                                  (table.insert rates
                                                {: messages
                                                 : span
                                                 :yield ?yield!})
                                  (if ?rate
                                      (?rate messages span ?yield!)
                                      (values span 0)))
             :ask-good-moment! (fn [messages on-good]
                                 (table.insert asks {: messages : on-good}))}
            rates asks)))

(fn disabled-decide! []
  "Load the real decide.compaction over a disabled service stub that records
   each enabled? check and any question it is asked."
  (let [asked {:checks 0}]
    (tset package.loaded :fen.extensions.decide.service
          {:enabled? (fn [] (set asked.checks (+ asked.checks 1))
                       false)
           :max-request-bytes 60000
           :ask (fn [] (table.insert asked :ask) nil)
           :ask-async! (fn [_st _qs on-done]
                         (table.insert asked :ask-async!)
                         (on-done nil))})
    (tset package.loaded :fen.extensions.decide.compaction nil)
    asked))

(fn summarizer []
  "complete-messages mock that records the summarizer prompt text."
  (let [seen {:prompt nil :calls 0}]
    (values (fn [_agent messages _model _opts _on-event _yield-fn]
              (set seen.calls (+ seen.calls 1))
              (set seen.prompt (. messages 1 :content))
              (make-assistant "summary text")) seen)))

(fn run-tool! [state]
  (let [tool (registered-tool :compact)]
    (tool.execute {} {:state state} (fn [] nil))))

(fn has? [s needle]
  (not= nil (string.find (or s "") needle 1 true)))

(fn stub-bash [_messages span]
  (let [out [(table.unpack span)]]
    (tset out 4
          (types.tool-result-message {:tool-call-id "tc2"
                                      :tool-name :bash
                                      :content [(types.text-block "STUB-BASH")]}))
    (values out 1)))

(describe "extensions.compact tool-result rating call site"
          (fn []
            (after_each restore-modules!)
            (it "summarizes the span decide.compaction returns and reports the stub count"
                (fn []
                  (let [(complete prompt) (summarizer)
                        (decide rates) (mock-decide-compaction stub-bash)
                        seen (fresh complete decide)
                        state (tool-state)
                        result (run-tool! state)]
                    (assert.is_false result.is-error?)
                    (assert.are.equal 1 (length rates))
                    (let [rate (. rates 1)]
                      (assert.are.equal 5 (length rate.span))
                      (assert.are.equal (. state._test.original 7)
                                        (. rate.messages 7))
                      (assert.is_not_nil rate.yield))
                    (assert.is_true (has? prompt.prompt "READ-HEAD"))
                    (assert.is_true (has? prompt.prompt "STUB-BASH"))
                    (assert.is_false (has? prompt.prompt "BASH-HEAD"))
                    (assert.is_true (has? prompt.prompt "tiny"))
                    ;; Stubs live only in the summarizer copy.
                    (assert.is_true (has? (. state._test.original 4 :content 1
                                             :text)
                                          "BASH-HEAD"))
                    (let [done (last-event seen :compaction-summary)
                          entry (. state._test.entries 1)]
                      (assert.are.equal 1 done.tool-results-dropped)
                      (assert.is_nil entry.tool-results-dropped)))))
            (it "with decide disabled asks nothing and summarizes the span unchanged"
                (fn []
                  (let [(complete prompt) (summarizer)
                        asked (disabled-decide!)
                        seen (fresh complete)
                        state (tool-state)
                        result (run-tool! state)]
                    (assert.is_false result.is-error?)
                    (assert.is_true (> asked.checks 0))
                    (assert.are.equal 0 (length asked))
                    (assert.is_true (has? prompt.prompt "READ-HEAD"))
                    (assert.is_true (has? prompt.prompt "BASH-HEAD"))
                    (assert.are.equal 0
                                      (. (last-event seen :compaction-summary)
                                         :tool-results-dropped)))))
            (it "passes the compaction yield to decide and propagates tool cancellation"
                (fn []
                  (let [(complete prompt) (summarizer)
                        (decide rates) (mock-decide-compaction (fn [_messages
                                                                    span
                                                                    yield!]
                                                                 (yield!)
                                                                 (values span 0)))
                        seen (fresh complete decide)
                        state (tool-state)
                        tool (registered-tool :compact)
                        cancel-marker {:type :test-cancel}
                        (ok? err) (pcall tool.execute {} {:state state}
                                         (fn [] (error cancel-marker)))]
                    (assert.is_false ok?)
                    (assert.are.equal cancel-marker err)
                    (assert.are.equal 1 (length rates))
                    (assert.are.equal 0 prompt.calls)
                    (assert.are.equal 0 (length state._test.entries))
                    (assert.are.equal (length state._test.original)
                                      (length state.agent.messages))
                    (assert.are.equal 1 (event-count seen :llm-end)))))
            (it "/compact cancellation during rating writes nothing"
                (fn []
                  (let [(complete prompt) (summarizer)
                        (decide _rates) (mock-decide-compaction (fn [_messages
                                                                     span
                                                                     yield!]
                                                                  (yield!)
                                                                  (values span
                                                                          0)))
                        seen (fresh complete decide)
                        state (tool-state)]
                    (command-registry.dispatch "/compact" state)
                    (let [(ok1? err1) (coroutine.resume state.turn)]
                      (assert.is_true ok1? err1))
                    (set state.cancel-requested? true)
                    (let [(ok2? err2) (coroutine.resume state.turn)]
                      (assert.is_true ok2? err2))
                    (assert.are.equal :dead (coroutine.status state.turn))
                    (assert.are.equal 0 prompt.calls)
                    (assert.are.equal 0 (length state._test.entries))
                    (assert.are.equal 1 (event-count seen :cancelled)))))))

;; ----------------------------------------------------------------
;; Auto-compaction and its moment (#115, #511)
;; ----------------------------------------------------------------

(fn context-tokens [compact state]
  (compact._test.messages-tokens state.agent.messages))

(fn complete-turn! [state ?status]
  "Emit the runtime's turn-complete event, then the next idle tick."
  (events.emit {:type :agent-turn-complete
                :agent state.agent
                :state state
                :turn-id state.turn-id
                :status (or ?status :ok)})
  (events.emit {:type :runtime-tick
                :busy? (not (not state.busy?))
                :agent state.agent}))

(fn drain! [state]
  "Pump state.turn to completion the way interactive's on-tick does, including
   the turn-complete event and following tick for the compaction's own turn."
  (var ok? true)
  (while (and ok? state.turn (not= (coroutine.status state.turn) :dead))
    (set ok? (coroutine.resume state.turn)))
  (set state.turn nil)
  (set state.busy? false)
  (complete-turn! state (if ok? :ok :error))
  ok?)

(describe "extensions.compact auto-compaction"
          (fn []
            (after_each restore-modules!)
            (it "never compacts without the setting"
                (fn []
                  (let [(decide _rates asks) (mock-decide-compaction)
                        state (make-state)
                        seen (fresh (fn [] (make-assistant "unused")) decide
                                    nil)]
                    (complete-turn! state)
                    (assert.is_nil state.turn)
                    (assert.are.equal 0 (length asks))
                    (assert.are.equal 0 (event-count seen :error)))))
            (it "compacts at the threshold with trigger :auto and does not repeat"
                (fn []
                  (let [(decide _rates asks) (mock-decide-compaction)
                        state (make-state)
                        (_ compact) (fresh (fn [] (make-assistant "unused"))
                                           decide {})
                        threshold (context-tokens compact state)
                        seen (fresh (fn [_a _m _mo _o _e yield-fn]
                                      (yield-fn)
                                      (make-assistant "auto summary"))
                                    decide {:autoCompactTokens threshold})]
                    (complete-turn! state)
                    (assert.is_not_nil state.turn)
                    (assert.is_true state.busy?)
                    (assert.are.equal 0 (length asks))
                    (assert.is_true (has? (. (last-event seen :info) :text)
                                          "autoCompactTokens"))
                    (assert.is_true (drain! state))
                    (assert.are.equal 1 (length state._test.entries))
                    (assert.are.equal :auto (. state._test.entries 1 :trigger))
                    (assert.are.equal :auto
                                      (. (last-event seen :compaction-summary)
                                         :trigger))
                    ;; The compaction's own completion and later ticks start nothing new.
                    (assert.is_nil state.turn)
                    (events.emit {:type :runtime-tick
                                  :busy? false
                                  :agent state.agent})
                    (assert.is_nil state.turn)
                    (assert.are.equal 1 (length state._test.entries)))))
            (it "only compacts on a tick after the turn completes"
                (fn []
                  (let [state (make-state)
                        (_ compact) (fresh (fn [] (make-assistant "unused"))
                                           nil {})
                        threshold (context-tokens compact state)]
                    (fresh (fn [] (make-assistant "auto summary")) nil
                           {:autoCompactTokens threshold})
                    ;; --print and json presenters emit the completion but never tick.
                    (events.emit {:type :agent-turn-complete
                                  :agent state.agent
                                  :state state
                                  :turn-id state.turn-id
                                  :status :ok})
                    (assert.is_nil state.turn))))
            (it "skips when a new turn is already running at the next tick"
                (fn []
                  (let [state (make-state)
                        (_ compact) (fresh (fn [] (make-assistant "unused"))
                                           nil {})
                        threshold (context-tokens compact state)
                        sentinel (coroutine.create (fn [] nil))]
                    (fresh (fn [] (make-assistant "auto summary")) nil
                           {:autoCompactTokens threshold})
                    (events.emit {:type :agent-turn-complete
                                  :agent state.agent
                                  :state state
                                  :turn-id state.turn-id
                                  :status :ok})
                    ;; e.g. a goal iteration or queued follow-up started in the same tick
                    (set state.turn sentinel)
                    (set state.busy? true)
                    (set state.turn-id 2)
                    (events.emit {:type :runtime-tick
                                  :busy? true
                                  :agent state.agent})
                    (assert.are.equal sentinel state.turn)
                    (assert.are.equal 0 (length state._test.entries)))))
            (it "does not evaluate a cancelled turn"
                (fn []
                  (let [state (make-state)
                        (_ compact) (fresh (fn [] (make-assistant "unused"))
                                           nil {})
                        threshold (context-tokens compact state)]
                    (fresh (fn [] (make-assistant "auto summary")) nil
                           {:autoCompactTokens threshold})
                    (complete-turn! state :cancelled)
                    (assert.is_nil state.turn))))
            (it "skips silently without a session backend that can persist compactions"
                (fn []
                  (let [state (make-state)
                        (_ compact) (fresh (fn [] (make-assistant "unused"))
                                           nil {})
                        threshold (context-tokens compact state)
                        seen (fresh (fn [] (make-assistant "unused")) nil
                                    {:autoCompactTokens threshold})]
                    (set state.session-backend {})
                    (complete-turn! state)
                    (assert.is_nil state.turn)
                    (assert.are.equal 0 (event-count seen :error)))))
            (it "reports a failed auto-compaction once and does not retry the same turn"
                (fn []
                  (let [calls {:n 0}
                        state (make-state)
                        (_ compact) (fresh (fn [] (make-assistant "unused"))
                                           nil {})
                        threshold (context-tokens compact state)]
                    (fresh (fn []
                             (set calls.n (+ calls.n 1))
                             (error "summarizer down"))
                           nil {:autoCompactTokens threshold})
                    (complete-turn! state)
                    (assert.is_not_nil state.turn)
                    (assert.is_false (drain! state))
                    (assert.is_nil state.turn)
                    (complete-turn! state :error)
                    (assert.is_nil state.turn)
                    (assert.are.equal 1 calls.n)
                    (assert.are.equal 0 (length state._test.entries))
                    ;; The next real turn is evaluated again.
                    (set state.turn-id 2)
                    (complete-turn! state)
                    (assert.is_not_nil state.turn))))
            (it "compacts early inside the soft window when decide rates a good moment"
                (fn []
                  (let [(decide _rates asks) (mock-decide-compaction)
                        state (make-state)
                        (_ compact) (fresh (fn [] (make-assistant "unused"))
                                           decide {})
                        n (context-tokens compact state)
                        seen (fresh (fn [] (make-assistant "early summary"))
                                    decide
                                    {:autoCompactTokens (math.floor (/ n 0.9))})]
                    (complete-turn! state)
                    (assert.is_nil state.turn)
                    (assert.are.equal 1 (length asks))
                    (let [ask (. asks 1)]
                      (assert.are.equal state.agent.messages ask.messages)
                      (ask.on-good))
                    (assert.is_not_nil state.turn)
                    (assert.is_true (has? (. (last-event seen :info) :text)
                                          "compacting early"))
                    (assert.is_true (drain! state))
                    (assert.are.equal :auto (. state._test.entries 1 :trigger))
                    (assert.are.equal "early summary"
                                      (. (last-event seen :compaction-summary)
                                         :summary))
                    ;; The compaction's completion does not ask again.
                    (assert.are.equal 1 (length asks)))))
            (it "defers inside the soft window until decide calls back"
                (fn []
                  (let [(decide _rates asks) (mock-decide-compaction)
                        state (make-state)
                        (_ compact) (fresh (fn [] (make-assistant "unused"))
                                           decide {})
                        n (context-tokens compact state)]
                    (fresh (fn [] (make-assistant "unused")) decide
                           {:autoCompactTokens (math.floor (/ n 0.9))})
                    (complete-turn! state)
                    (assert.are.equal 1 (length asks))
                    (assert.is_nil state.turn)
                    ;; A later tick for the same turn does not ask again.
                    (events.emit {:type :runtime-tick
                                  :busy? false
                                  :agent state.agent})
                    (assert.are.equal 1 (length asks))
                    ;; The next completed turn asks once more.
                    (set state.turn-id 2)
                    (complete-turn! state)
                    (assert.are.equal 2 (length asks)))))
            (it "ignores a good-moment answer once the runtime moved on"
                (fn []
                  (let [(decide _rates asks) (mock-decide-compaction)
                        state (make-state)
                        (_ compact) (fresh (fn [] (make-assistant "unused"))
                                           decide {})
                        n (context-tokens compact state)
                        sentinel (coroutine.create (fn [] nil))]
                    (fresh (fn [] (make-assistant "unused")) decide
                           {:autoCompactTokens (math.floor (/ n 0.9))})
                    (complete-turn! state)
                    ;; Busy with a new turn when the answer lands.
                    (set state.turn sentinel)
                    (set state.busy? true)
                    ((. asks 1 :on-good))
                    (assert.are.equal sentinel state.turn)
                    ;; Idle again, but on a later turn.
                    (set state.turn nil)
                    (set state.busy? false)
                    (set state.turn-id 2)
                    ((. asks 1 :on-good))
                    (assert.is_nil state.turn)
                    (assert.are.equal 0 (length state._test.entries)))))
            (it "with decide disabled asks nothing and only compacts at the threshold"
                (fn []
                  (let [asked (disabled-decide!)
                        state (make-state)
                        (_ compact) (fresh (fn [] (make-assistant "unused"))
                                           nil {})
                        n (context-tokens compact state)]
                    (fresh (fn [] (make-assistant "unused")) nil
                           {:autoCompactTokens (math.floor (/ n 0.9))})
                    (complete-turn! state)
                    (assert.is_nil state.turn)
                    (assert.is_true (> asked.checks 0))
                    (assert.are.equal 0 (length asked))
                    (fresh (fn [] (make-assistant "ceiling summary")) nil
                           {:autoCompactTokens n})
                    (complete-turn! state)
                    (assert.is_not_nil state.turn)
                    (assert.are.equal 0 (length asked)))))
            (it "stays quiet below the soft window"
                (fn []
                  (let [(decide _rates asks) (mock-decide-compaction)
                        state (make-state)
                        (_ compact) (fresh (fn [] (make-assistant "unused"))
                                           decide {})
                        n (context-tokens compact state)]
                    (fresh (fn [] (make-assistant "unused")) decide
                           {:autoCompactTokens (+ (math.ceil (/ n 0.8)) 10)})
                    (complete-turn! state)
                    (assert.is_nil state.turn)
                    (assert.are.equal 0 (length asks)))))))
