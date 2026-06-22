;; Tests for core.agent's COOPERATIVE/transport contract — yield cadence,
;; native stream/coop dispatch, and cancellation.
;;
;; Strategy: install a fake `core.llm` into package.loaded *before* requiring
;; `core.agent`. agent.fnl does `(local llm (require :fen.core.llm))` at module
;; load, so the first require resolves to our fake. These cases program the
;; dispatcher directly (stream/coop sub-methods, yield counting, cancel-fn) and
;; cannot be expressed as a response-only provider.
;;
;; The blocking-mode coverage (response shape, tool dispatch, steering/follow-up,
;; safety cap, message conversion, recording what the agent sent) lives in
;; `extensions/adapters/providers/mock/tests/agent_loop_test.fnl`, driven through
;; the real dispatcher + the deterministic mock provider. A core test cannot
;; depend on an extension provider, hence the split.

(local types (require :fen.core.types))

(local fake
  {:calls []
   :coop-calls []
   :responses []
   :default-response nil
   ;; The fake stands in for `core.llm` (the dispatcher), not a single
   ;; provider. `complete` mirrors the real dispatcher's routing: when
   ;; `complete-stream` or `complete-coop` are set on the fake, they win
   ;; over the blocking path. Tests queue or set canonical AssistantMessages
   ;; as responses.
   :reset (fn [self]
            (set self.calls [])
            (set self.coop-calls [])
            (set self.responses [])
            (set self.default-response nil)
            ;; Clear any streaming/coop methods previous tests installed so
            ;; the default dispatch path is "no coop, fall back to complete".
            (set self.complete-stream nil)
            (set self.complete-coop nil))})

(fn shallow-copy [t]
  (let [out []]
    (each [_ v (ipairs t)] (table.insert out v))
    out))

(fn snapshot-context [api model context options]
  ;; agent.messages is mutated in place across iterations; without copying
  ;; the message list a recorded call drifts as the loop runs.
  {: api : model
   :options options
   :context {:system-prompt context.system-prompt
             :tools context.tools
             :messages (shallow-copy context.messages)}})

(fn blocking-complete [api model context options]
  (table.insert fake.calls (snapshot-context api model context options))
  (let [r (table.remove fake.responses 1)]
    (or r fake.default-response
        (types.assistant-message
          {:api api :provider :test :model model
           :content [(types.text-block "fallback")]
           :stop-reason :stop}))))

(fn fake.complete [api model context options ?on-event ?yield-fn]
  (if (and ?on-event fake.complete-stream)
      (fake.complete-stream api model context options ?on-event ?yield-fn)
      (and ?yield-fn fake.complete-coop)
      (fake.complete-coop api model context options ?yield-fn)
      (blocking-complete api model context options)))

(tset package.loaded :fen.core.llm fake)

(local agent-mod (require :fen.core.agent))

;; ---- helpers for building canonical fake AssistantMessages -------

(fn text-response [text]
  (types.assistant-message
    {:api :openai-completions :provider :openai :model "mock"
     :content [(types.text-block text)]
     :stop-reason :stop}))

(fn error-response [msg]
  (types.assistant-message
    {:api :openai-completions :provider :openai :model "mock"
     :content [(types.text-block (.. "[error] " msg))]
     :stop-reason :error
     :error-message msg}))

(fn record-events []
  (let [log []]
    (values log (fn [ev] (table.insert log ev)))))

(fn ui-events [log]
  "UI/event-taxonomy helper. Lifecycle append events are asserted separately."
  (let [out []]
    (each [_ ev (ipairs log)]
      (when (not= ev.type :message-appended)
        (table.insert out ev)))
    out))

(fn event-types [log]
  (let [out []]
    (each [_ ev (ipairs (ui-events log))] (table.insert out ev.type))
    out))

(fn message-tool-call-ids [messages start stop]
  (let [out []]
    (for [i start stop]
      (table.insert out (. messages i :tool-call-id)))
    out))

(fn message-first-text [message]
  (or (?. message :content 1 :text) ""))

(fn stub-registry [output]
  [{:name :noop :label "Noop"
    :description "no-op"
    :parameters {:type :object :properties {}}
    :execute (fn [_]
               {:content [(types.text-block output)] :is-error? false})}])

(fn tool-use-response [calls]
  (types.assistant-message
    {:api :openai-completions :provider :openai :model "mock"
     :content calls
     :stop-reason :tool-use}))

(fn raw-unsafe-count [s]
  (var n 0)
  (for [i 1 (length s)]
    (let [b (string.byte s i)]
      (when (or (and (< b 32) (not (or (= b 9) (= b 10) (= b 13))))
                (= b 127))
        (set n (+ n 1)))))
  n)

;; ----------------------------------------------------------------


(fn drain-coop-with [agent user-msg cancel-fn]
  "Run step inside a coroutine with an optional cancel-fn to completion,
   counting how many times the coroutine yields. Used to prove the loop
   actually releases control between phases rather than running straight
   through. (Cooperative mode is auto-detected by `step` from the active
   coroutine.)"
  (let [co (coroutine.create
             (fn [] (agent-mod.step agent user-msg cancel-fn)))]
    (var yields 0)
    (var final nil)
    (var alive? true)
    (while alive?
      (let [(ok? r) (coroutine.resume co)]
        (assert.is_true ok?)
        (if (= (coroutine.status co) :dead)
            (do (set final r) (set alive? false))
            (set yields (+ yields 1)))))
    (values final yields)))

(fn drain-coop [agent user-msg]
  (drain-coop-with agent user-msg nil))

(describe "core.agent.step (cooperative mode)"
  (fn []
    (before_each (fn [] (fake:reset)))

    (it "yields between phases on a single-turn text response"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:provider-name :openai
                       :model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})]
          (set fake.default-response (text-response "hello"))
          (let [(final yields) (drain-coop agent "hi")]
            (assert.are.equal "hello" final)
            ;; yields after :llm-start and after :llm-end (2 total)
            (assert.are.equal 2 yields)
            (assert.are.same [:llm-start :llm-end :assistant-text]
                             (event-types log))))))

    (it "yields between each tool call so multi-tool turns release the loop"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "tool ran")
                       :on-event on-event})]
          (table.insert fake.responses
                        (types.assistant-message
                          {:api :openai-completions :provider :openai
                           :model "mock"
                           :content [(types.tool-call-block "c1" :noop {})
                                     (types.tool-call-block "c2" :noop {})]
                           :stop-reason :tool-use}))
          (table.insert fake.responses (text-response "done"))
          (let [(final yields) (drain-coop agent "go")]
            (assert.are.equal "done" final)
            ;; Turn 1: yield after llm-start, after llm-end, before c1, after c1,
            ;; before c2, after c2. Turn 2: yield after llm-start, after llm-end.
            ;; = 8 yields total.
            (assert.are.equal 8 yields)
            (assert.are.same
              [:llm-start :llm-end
               :tool-call :tool-result
               :tool-call :tool-result
               :llm-start :llm-end :assistant-text]
              (event-types log))))))

    (it "runs parallel-safe tool calls concurrently with cap 4"
      (fn []
        (let [state {:active 0 :max-active 0 :starts []}
              tools [{:name :worker :label "Worker"
                      :description "parallel worker"
                      :parameters {:type :object :properties {}}
                      :parallel-safe? true
                      :parallel-cap 4
                      :execute (fn [args _ctx yield-fn]
                                 (set state.active (+ state.active 1))
                                 (set state.max-active (math.max state.max-active
                                                                 state.active))
                                 (table.insert state.starts args.id)
                                 (yield-fn)
                                 (set state.active (- state.active 1))
                                 {:content [(types.text-block args.id)]
                                  :is-error? false})}]
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools tools})]
          (table.insert fake.responses
                        (tool-use-response
                          [(types.tool-call-block "c1" :worker {:id "1"})
                           (types.tool-call-block "c2" :worker {:id "2"})
                           (types.tool-call-block "c3" :worker {:id "3"})
                           (types.tool-call-block "c4" :worker {:id "4"})
                           (types.tool-call-block "c5" :worker {:id "5"})]))
          (table.insert fake.responses (text-response "done"))
          (let [(final _yields) (drain-coop agent "go")]
            (assert.are.equal "done" final)
            (assert.are.equal 4 state.max-active)
            (assert.are.same ["1" "2" "3" "4" "5"] state.starts)
            (assert.are.same ["c1" "c2" "c3" "c4" "c5"]
                             (message-tool-call-ids agent.messages 3 7))))))

    (it "honors non-default parallel-safe caps"
      (fn []
        (let [state {:active 0 :max-active 0}
              tools [{:name :worker :label "Worker"
                      :description "parallel worker"
                      :parameters {:type :object :properties {}}
                      :parallel-safe? true
                      :parallel-cap 2
                      :execute (fn [args _ctx yield-fn]
                                 (set state.active (+ state.active 1))
                                 (set state.max-active (math.max state.max-active
                                                                 state.active))
                                 (yield-fn)
                                 (set state.active (- state.active 1))
                                 {:content [(types.text-block args.id)]
                                  :is-error? false})}]
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools tools})]
          (table.insert fake.responses
                        (tool-use-response
                          [(types.tool-call-block "c1" :worker {:id "1"})
                           (types.tool-call-block "c2" :worker {:id "2"})
                           (types.tool-call-block "c3" :worker {:id "3"})
                           (types.tool-call-block "c4" :worker {:id "4"})
                           (types.tool-call-block "c5" :worker {:id "5"})]))
          (table.insert fake.responses (text-response "done"))
          (let [(final _yields) (drain-coop agent "go")]
            (assert.are.equal "done" final)
            (assert.are.equal 2 state.max-active)
            (assert.are.same ["c1" "c2" "c3" "c4" "c5"]
                             (message-tool-call-ids agent.messages 3 7))))))

    (it "preserves result order when parallel-safe calls finish out of order"
      (fn []
        (let [state {:finishes []}
              tools [{:name :worker :label "Worker"
                      :description "parallel worker"
                      :parameters {:type :object :properties {}}
                      :parallel-safe? true
                      :parallel-cap 4
                      :execute (fn [args _ctx yield-fn]
                                 (for [_ 1 (or args.waits 1)]
                                   (yield-fn))
                                 (table.insert state.finishes args.id)
                                 {:content [(types.text-block args.id)]
                                  :is-error? false})}]
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools tools})]
          (table.insert fake.responses
                        (tool-use-response
                          [(types.tool-call-block "c1" :worker {:id "slow" :waits 2})
                           (types.tool-call-block "c2" :worker {:id "fast" :waits 1})]))
          (table.insert fake.responses (text-response "done"))
          (let [(final _yields) (drain-coop agent "go")]
            (assert.are.equal "done" final)
            (assert.are.same ["fast" "slow"] state.finishes)
            (assert.are.same ["c1" "c2"]
                             (message-tool-call-ids agent.messages 3 4))))))

    (it "records one failed parallel-safe call while siblings complete"
      (fn []
        (let [tools [{:name :worker :label "Worker"
                      :description "parallel worker"
                      :parameters {:type :object :properties {}}
                      :parallel-safe? true
                      :parallel-cap 4
                      :execute (fn [args _ctx yield-fn]
                                 (yield-fn)
                                 (if args.fail?
                                     (error "boom")
                                     {:content [(types.text-block args.id)]
                                      :is-error? false}))}]
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools tools})]
          (table.insert fake.responses
                        (tool-use-response
                          [(types.tool-call-block "c1" :worker {:id "ok-1"})
                           (types.tool-call-block "c2" :worker {:id "bad" :fail? true})
                           (types.tool-call-block "c3" :worker {:id "ok-3"})]))
          (table.insert fake.responses (text-response "done"))
          (let [(final _yields) (drain-coop agent "go")]
            (assert.are.equal "done" final)
            (assert.are.same ["c1" "c2" "c3"]
                             (message-tool-call-ids agent.messages 3 5))
            (assert.is_false (. agent.messages 3 :is-error?))
            (assert.is_true (. agent.messages 4 :is-error?))
            (assert.is_false (. agent.messages 5 :is-error?))
            (assert.is_truthy
              (string.find (message-first-text (. agent.messages 4))
                           "error: tool worker failed:" 1 true))))))

    (it "keeps non-parallel-safe yielding tools sequential"
      (fn []
        (let [state {:active 0 :max-active 0}
              tools [{:name :worker :label "Worker"
                      :description "serial worker"
                      :parameters {:type :object :properties {}}
                      :execute (fn [args _ctx yield-fn]
                                 (set state.active (+ state.active 1))
                                 (set state.max-active (math.max state.max-active
                                                                 state.active))
                                 (yield-fn)
                                 (set state.active (- state.active 1))
                                 {:content [(types.text-block args.id)]
                                  :is-error? false})}]
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools tools})]
          (table.insert fake.responses
                        (tool-use-response
                          [(types.tool-call-block "c1" :worker {:id "1"})
                           (types.tool-call-block "c2" :worker {:id "2"})]))
          (table.insert fake.responses (text-response "done"))
          (let [(final _yields) (drain-coop agent "go")]
            (assert.are.equal "done" final)
            (assert.are.equal 1 state.max-active)))))

    (it "does not reorder mixed safe and unsafe tool calls"
      (fn []
        (let [state {:safe-active 0 :starts [] :unsafe-saw-safe-active nil}
              tools [{:name :safe :label "Safe"
                      :description "parallel worker"
                      :parameters {:type :object :properties {}}
                      :parallel-safe? true
                      :parallel-cap 4
                      :execute (fn [args _ctx yield-fn]
                                 (set state.safe-active (+ state.safe-active 1))
                                 (table.insert state.starts args.id)
                                 (yield-fn)
                                 (set state.safe-active (- state.safe-active 1))
                                 {:content [(types.text-block args.id)]
                                  :is-error? false})}
                     {:name :unsafe :label "Unsafe"
                      :description "serial worker"
                      :parameters {:type :object :properties {}}
                      :execute (fn [args]
                                 (table.insert state.starts args.id)
                                 (set state.unsafe-saw-safe-active state.safe-active)
                                 {:content [(types.text-block args.id)]
                                  :is-error? false})}]
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools tools})]
          (table.insert fake.responses
                        (tool-use-response
                          [(types.tool-call-block "c1" :safe {:id "s1"})
                           (types.tool-call-block "c2" :safe {:id "s2"})
                           (types.tool-call-block "c3" :unsafe {:id "u3"})
                           (types.tool-call-block "c4" :safe {:id "s4"})]))
          (table.insert fake.responses (text-response "done"))
          (let [(final _yields) (drain-coop agent "go")]
            (assert.are.equal "done" final)
            (assert.are.same ["s1" "s2" "u3" "s4"] state.starts)
            (assert.are.equal 0 state.unsafe-saw-safe-active)
            (assert.are.same ["c1" "c2" "c3" "c4"]
                             (message-tool-call-ids agent.messages 3 6))))))

    (it "cancels a parallel-safe batch with paired tool results"
      (fn []
        (let [tools [{:name :worker :label "Worker"
                      :description "parallel worker"
                      :parameters {:type :object :properties {}}
                      :parallel-safe? true
                      :parallel-cap 4
                      :execute (fn [_args _ctx yield-fn]
                                 (while true
                                   (yield-fn)))}]
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools tools})
              cancel-state {:n 0}
              cancel-fn (fn []
                          (set cancel-state.n (+ cancel-state.n 1))
                          (>= cancel-state.n 4))]
          (table.insert fake.responses
                        (tool-use-response
                          [(types.tool-call-block "c1" :worker {})
                           (types.tool-call-block "c2" :worker {})
                           (types.tool-call-block "c3" :worker {})
                           (types.tool-call-block "c4" :worker {})
                           (types.tool-call-block "c5" :worker {})]))
          (let [(final _yields) (drain-coop-with agent "go" cancel-fn)]
            (assert.are.equal "[cancelled]" final)
            (assert.are.equal 8 (length agent.messages))
            (assert.are.equal :tool-result (. agent.messages 3 :role))
            (assert.are.same ["c1" "c2" "c3" "c4" "c5"]
                             (message-tool-call-ids agent.messages 3 7))
            (assert.is_true (. agent.messages 7 :is-error?))
            (assert.are.equal :aborted (. agent.messages 8 :stop-reason))))))

    (it "stops cleanly on an error stop-reason"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})]
          (set fake.default-response (error-response "boom"))
          (let [(final _yields) (drain-coop agent "hi")]
            (assert.are.equal "[error] boom" final)
            (let [types-list (event-types log)]
              (var has-error? false)
              (each [_ t (ipairs types-list)]
                (when (= t :error) (set has-error? true)))
              (assert.is_true has-error?))))))

    (it "falls back to complete when the provider has no complete-coop"
      (fn []
        (let [(_log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})]
          ;; fake:reset clears any complete-coop, so llm.complete falls
          ;; back to fake.complete here (the blocking transport).
          (set fake.default-response (text-response "fallback ok"))
          (let [(final _yields) (drain-coop agent "hi")]
            (assert.are.equal "fallback ok" final)
            (assert.are.equal 1 (length fake.calls))
            (assert.are.equal 0 (length fake.coop-calls))))))

    (it "dispatches to complete-coop and threads yield-fn through"
      (fn []
        (let [(_log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})]
          ;; A coop-aware fake: record the call, then exercise yield-fn the
          ;; way the curl backend's cooperative driver would (one yield per
          ;; transfer step) so we can assert the agent threads it through.
          (set fake.complete-coop
               (fn [api model context options yield-fn]
                 (table.insert fake.coop-calls
                               {: api : model
                                :has-yield? (= (type yield-fn) :function)})
                 (when yield-fn (yield-fn))
                 (when yield-fn (yield-fn))
                 (or fake.default-response
                     (types.assistant-message
                       {:api api :provider :test :model model
                        :content [(types.text-block "coop ok")]
                        :stop-reason :stop}))))
          (set fake.default-response (text-response "coop ok"))
          (let [(final yields) (drain-coop agent "hi")]
            (assert.are.equal "coop ok" final)
            ;; complete-coop ran instead of complete.
            (assert.are.equal 0 (length fake.calls))
            (assert.are.equal 1 (length fake.coop-calls))
            (assert.is_true (. fake.coop-calls 1 :has-yield?))
            ;; Yields = 1 (after :llm-start) + 2 (inside complete-coop)
            ;; + 1 (after :llm-end) = 4.
            (assert.are.equal 4 yields)))))

    (it "forwards provider stream deltas without duplicating final text"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})]
          (set fake.complete-stream
               (fn [api model context options on-stream yield-fn]
                 (when yield-fn (yield-fn))
                 (on-stream {:type :start})
                 (on-stream {:type :text-start :content-index 1})
                 (on-stream {:type :text-delta :content-index 1 :delta "co"})
                 (on-stream {:type :text-delta :content-index 1 :delta "op"})
                 (let [asst (types.assistant-message
                              {:api api :provider :test :model model
                               :content [(types.text-block "coop")]
                               :stop-reason :stop})]
                   (on-stream {:type :text-end :content-index 1 :content "coop"})
                   (on-stream {:type :done :message asst})
                   asst)))
          (let [(final yields) (drain-coop agent "hi")]
            (assert.are.equal "coop" final)
            (assert.are.equal 3 yields)
            (assert.are.same [:llm-start
                              :assistant-text-delta :assistant-text-delta
                              :llm-end :assistant-stream-end]
                             (event-types log))))))

    (it "sanitizes synthetic cancelled tool-result text"
      (fn []
        (let [(_log on-event) (record-events)
              poison (.. "ran" (string.char 0) (string.char 255))
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry poison)
                       :on-event on-event})
              cancel-state {:n 0}
              cancel-fn (fn []
                          (set cancel-state.n (+ cancel-state.n 1))
                          (>= cancel-state.n 5))]
          (table.insert fake.responses
                        (types.assistant-message
                          {:api :openai-completions :provider :openai
                           :model "mock"
                           :content [(types.tool-call-block "c1" :noop {})
                                     (types.tool-call-block "c2" :noop {})]
                           :stop-reason :tool-use}))
          (let [(final _yields) (drain-coop-with agent "go" cancel-fn)]
            (assert.are.equal "[cancelled]" final)
            (let [first-body (. agent.messages 3 :content 1 :text)
                  cancelled-body (. agent.messages 4 :content 1 :text)]
              (assert.are.equal 0 (raw-unsafe-count first-body))
              (assert.is_truthy (string.find first-body "\\x00" 1 true))
              (assert.is_truthy (string.find first-body "\\xFF" 1 true))
              (assert.are.equal 0 (raw-unsafe-count cancelled-body))
              (assert.is_truthy (string.find cancelled-body "cancelled" 1 true)))))))

    (it "keeps the user message and appends an aborted assistant when cancel-fn fires"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})
              ;; cancel-fn always returns true, so the very first yield
              ;; after :llm-start raises CANCEL-MARKER and unwinds.
              cancel-fn (fn [] true)]
          (set fake.default-response (text-response "should not appear"))
          (let [co (coroutine.create
                     (fn [] (agent-mod.step agent "hi" cancel-fn)))]
            ;; First resume: runs until the post-:llm-start yield.
            (coroutine.resume co)
            ;; Second resume: yield-helper checks cancel-fn → raises →
            ;; pcall catches, rollback runs, :cancelled emitted.
            (let [(ok? final) (coroutine.resume co)]
              (assert.is_true ok?)
              (assert.are.equal :dead (coroutine.status co))
              (assert.are.equal "[cancelled]" final)
              ;; Cancellation is persisted as history: the user message stays
              ;; and an empty assistant with stop-reason :aborted is appended.
              (assert.are.equal 2 (length agent.messages))
              (assert.are.equal :user (. agent.messages 1 :role))
              (assert.are.equal :assistant (. agent.messages 2 :role))
              (assert.are.equal :aborted (. agent.messages 2 :stop-reason))
              ;; The first yield (after :llm-start) raises before the
              ;; LLM call runs, so no provider call ever happens.
              (assert.are.equal 0 (length fake.calls))
              (let [types-list (event-types log)]
                (var has-cancelled? false)
                (var has-assistant-text? false)
                (each [_ t (ipairs types-list)]
                  (when (= t :cancelled) (set has-cancelled? true))
                  (when (= t :assistant-text) (set has-assistant-text? true)))
                (assert.is_true has-cancelled?)
                ;; The assistant text from the queued response never arrived.
                (assert.is_false has-assistant-text?)))))))

    (it "aborts mid-tool-loop without rolling back prior messages"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "tool ran")
                       :on-event on-event})
              ;; cancel-fn returns true on its 5th call. Yield ordering:
              ;;   1: after :llm-start
              ;;   2: after :llm-end (assistant message appended)
              ;;   3: before tool 1 execute
              ;;   4: after tool 1 result appended
              ;;   5: before tool 2 execute  ← cancel here; agent appends
              ;;      a synthetic cancelled tool-result for tool 2 before
              ;;      unwinding so provider history remains valid.
              cancel-state {:n 0}
              cancel-fn (fn []
                          (set cancel-state.n (+ cancel-state.n 1))
                          (>= cancel-state.n 5))]
          (table.insert fake.responses
                        (types.assistant-message
                          {:api :openai-completions :provider :openai
                           :model "mock"
                           :content [(types.tool-call-block "c1" :noop {})
                                     (types.tool-call-block "c2" :noop {})]
                           :stop-reason :tool-use}))
          ;; Defensive: queue a follow-up that we expect never to run.
          (table.insert fake.responses (text-response "should not run"))
          (let [(final _yields) (drain-coop-with agent "go" cancel-fn)]
            (assert.are.equal "[cancelled]" final)
            ;; One tool actually executed; the second receives a synthetic
            ;; cancelled tool-result to satisfy the provider transcript
            ;; invariant that every tool-call has a result.
            (let [types-list (event-types log)
                  tool-results 0]
              (var n 0)
              (each [_ t (ipairs types-list)]
                (when (= t :tool-result) (set n (+ n 1))))
              (assert.are.equal 2 n))
            ;; No rollback: user, tool-use assistant, completed tool result,
            ;; synthetic cancelled tool result, and an aborted assistant marker
            ;; remain in history.
            (assert.are.equal 5 (length agent.messages))
            (assert.are.equal :user (. agent.messages 1 :role))
            (assert.are.equal :assistant (. agent.messages 2 :role))
            (assert.are.equal :tool-result (. agent.messages 3 :role))
            (assert.are.equal "c1" (. agent.messages 3 :tool-call-id))
            (assert.are.equal :tool-result (. agent.messages 4 :role))
            (assert.are.equal "c2" (. agent.messages 4 :tool-call-id))
            (assert.is_true (. agent.messages 4 :is-error?))
            (assert.are.equal :assistant (. agent.messages 5 :role))
            (assert.are.equal :aborted (. agent.messages 5 :stop-reason))
            ;; Only the first LLM call ran (the loop never reached a
            ;; second iteration).
            (assert.are.equal 1 (length fake.calls))))))

    (it "leaves messages untouched when cancel-fn is nil"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})]
          (set fake.default-response (text-response "ok"))
          (let [(final _yields) (drain-coop agent "hi")]
            (assert.are.equal "ok" final)
            ;; A normal turn persists the user msg + assistant msg.
            (assert.are.equal 2 (length agent.messages))
            (let [types-list (event-types log)]
              (var has-cancelled? false)
              (each [_ t (ipairs types-list)]
                (when (= t :cancelled) (set has-cancelled? true)))
              (assert.is_false has-cancelled?))))))))
