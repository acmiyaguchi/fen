;; Tests for core.agent — locks the safety cap, event taxonomy, canonical
;; message shape, and provider dispatch.
;;
;; Strategy: install a fake `core.llm` into package.loaded *before* requiring
;; `core.agent`. agent.fnl does `(local llm (require :fen.core.llm))` at module
;; load, so the first require resolves to our fake.

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

(fn tool-response [id name args]
  (types.assistant-message
    {:api :openai-completions :provider :openai :model "mock"
     :content [(types.tool-call-block id name args)]
     :stop-reason :tool-use}))

(fn multi-tool-response []
  (types.assistant-message
    {:api :openai-completions :provider :openai :model "mock"
     :content [(types.tool-call-block "call-1" :noop {})
               (types.tool-call-block "call-2" :noop {})
               (types.text-block "checking")]
     :stop-reason :tool-use}))

(fn thinking-text-response [thinking text]
  (types.assistant-message
    {:api :openai-completions :provider :openai :model "mock"
     :content [(types.thinking-block {:thinking thinking})
               (types.text-block text)]
     :stop-reason :stop}))

(fn thinking-tool-response [thinking id name args]
  (types.assistant-message
    {:api :openai-completions :provider :openai :model "mock"
     :content [(types.thinking-block {:thinking thinking})
               (types.tool-call-block id name args)]
     :stop-reason :tool-use}))

(fn error-response [msg]
  (types.assistant-message
    {:api :openai-completions :provider :openai :model "mock"
     :content [(types.text-block (.. "[error] " msg))]
     :stop-reason :error
     :error-message msg}))

(fn record-events []
  (let [log []]
    (values log (fn [ev] (table.insert log ev)))))

(fn event-types [log]
  (let [out []]
    (each [_ ev (ipairs log)] (table.insert out ev.type))
    out))

(fn stub-registry [output]
  [{:name :noop :label "Noop"
    :description "no-op"
    :parameters {:type :object :properties {}}
    :execute (fn [_]
               {:content [(types.text-block output)] :is-error? false})}])

;; ----------------------------------------------------------------

(describe "core.agent.step"
  (fn []
    (before_each (fn [] (fake:reset)))

    (it "stops after one turn when the model returns a final text"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:provider-api :openai-completions
                       :model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})]
          (set fake.default-response (text-response "hello"))
          (let [final (agent-mod.step agent "hi")]
            (assert.are.equal "hello" final)
            (assert.are.equal 1 (length fake.calls))
            (assert.are.same [:llm-start :llm-end :assistant-text]
                             (event-types log))))))

    (it "emits thinking rows before final assistant text"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})]
          (set fake.default-response (thinking-text-response "step by step" "answer"))
          (let [final (agent-mod.step agent "think")]
            (assert.are.equal "answer" final)
            (assert.are.same [:llm-start :llm-end :assistant-thinking :assistant-text]
                             (event-types log))
            (assert.are.equal "step by step" (. log 3 :text))
            (assert.is_false (. log 3 :final?))
            (assert.is_true (. log 3 :spacer-after?))
            (assert.are.equal "answer" (. log 4 :text))
            (assert.is_true (. log 4 :final?))))))

    (it "emits thinking rows before tool calls"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "tool ran")
                       :on-event on-event})]
          (table.insert fake.responses (thinking-tool-response "need a tool" "call-1" :noop {}))
          (table.insert fake.responses (text-response "done"))
          (let [final (agent-mod.step agent "use a tool")]
            (assert.are.equal "done" final)
            (assert.are.same
              [:llm-start :llm-end :assistant-thinking :tool-call :tool-result
               :llm-start :llm-end :assistant-text]
              (event-types log))))))

    (it "executes tool calls then continues until a stop"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "tool ran")
                       :on-event on-event})]
          (table.insert fake.responses (tool-response "call-1" :noop {}))
          (table.insert fake.responses (text-response "done"))
          (let [final (agent-mod.step agent "use a tool")]
            (assert.are.equal "done" final)
            (assert.are.equal 2 (length fake.calls))
            (assert.are.same
              [:llm-start :llm-end :tool-call :tool-result
               :llm-start :llm-end :assistant-text]
              (event-types log))))))

    (it "appends a canonical ToolResultMessage after each tool execution"
      (fn []
        (let [(_ on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "tool output")
                       :on-event on-event})]
          (table.insert fake.responses (tool-response "call-xyz" :noop {}))
          (table.insert fake.responses (text-response "ok"))
          (agent-mod.step agent "go")
          ;; Find the tool-result message.
          (var tr nil)
          (each [_ m (ipairs agent.messages)]
            (when (= m.role :tool-result) (set tr m)))
          (assert.is_table tr)
          (assert.are.equal "call-xyz" tr.tool-call-id)
          (assert.are.equal :noop tr.tool-name)
          (assert.is_false tr.is-error?)
          (assert.are.equal "tool output" (. tr.content 1 :text)))))

    (it "executes multiple tool calls from one assistant turn before continuing"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "tool output")
                       :on-event on-event})]
          (table.insert fake.responses (multi-tool-response))
          (table.insert fake.responses (text-response "done"))
          (let [final (agent-mod.step agent "go")]
            (assert.are.equal "done" final)
            (assert.are.same
              [:llm-start :llm-end :assistant-text
               :tool-call :tool-result :tool-call :tool-result
               :llm-start :llm-end :assistant-text]
              (event-types log))
            (assert.are.equal :assistant (. agent.messages 2 :role))
            (assert.are.equal :tool-result (. agent.messages 3 :role))
            (assert.are.equal "call-1" (. agent.messages 3 :tool-call-id))
            (assert.are.equal :tool-result (. agent.messages 4 :role))
            (assert.are.equal "call-2" (. agent.messages 4 :tool-call-id))
            (assert.are.equal :assistant (. agent.messages 5 :role))))))

    (it "injects steering messages before the next provider call"
      (fn []
        (let [(log on-event) (record-events)
              calls {:n 0}
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "tool output")
                       :on-event on-event
                       :get-steering (fn []
                                       (set calls.n (+ calls.n 1))
                                       (if (= calls.n 2) ["please steer"] []))})]
          (table.insert fake.responses (tool-response "call-1" :noop {}))
          (table.insert fake.responses (text-response "done"))
          (let [final (agent-mod.step agent "go")]
            (assert.are.equal "done" final)
            (assert.are.same
              [:llm-start :llm-end :tool-call :tool-result
               :steering-injected :llm-start :llm-end :assistant-text]
              (event-types log))
            (assert.are.equal :user (. agent.messages 4 :role))
            (assert.are.equal "please steer" (. agent.messages 4 :content))
            (assert.are.equal :assistant (. agent.messages 5 :role))
            (assert.are.equal "please steer"
                              (. fake.calls 2 :context :messages 4 :content))))))

    (it "injects steering queued during a natural stop before exiting"
      (fn []
        (let [(log on-event) (record-events)
              polls {:n 0}
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event
                       :get-steering (fn []
                                       (set polls.n (+ polls.n 1))
                                       ;; First poll is before the first LLM call;
                                       ;; second poll simulates text queued while
                                       ;; that response was in flight.
                                       (if (= polls.n 2) ["midrun steer"] []))})]
          (table.insert fake.responses (text-response "first done"))
          (table.insert fake.responses (text-response "second done"))
          (let [final (agent-mod.step agent "go")]
            (assert.are.equal "second done" final)
            (assert.are.same
              [:llm-start :llm-end :assistant-text
               :steering-injected :llm-start :llm-end :assistant-text]
              (event-types log))
            (assert.are.equal :user (. agent.messages 3 :role))
            (assert.are.equal "midrun steer" (. agent.messages 3 :content))
            (assert.are.equal "midrun steer"
                              (. fake.calls 2 :context :messages 3 :content))))))

    (it "prefers queued steering over follow-up after a natural stop"
      (fn []
        (let [(log on-event) (record-events)
              steering-polls {:n 0}
              followup-polls {:n 0}
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event
                       :get-steering (fn []
                                       (set steering-polls.n (+ steering-polls.n 1))
                                       (if (= steering-polls.n 2) ["steer first"] []))
                       :get-follow-up (fn []
                                        (set followup-polls.n (+ followup-polls.n 1))
                                        (if (= followup-polls.n 1) ["follow second"] []))})]
          (table.insert fake.responses (text-response "first done"))
          (table.insert fake.responses (text-response "second done"))
          (table.insert fake.responses (text-response "third done"))
          (let [final (agent-mod.step agent "go")]
            (assert.are.equal "third done" final)
            (assert.are.same
              [:llm-start :llm-end :assistant-text
               :steering-injected :llm-start :llm-end :assistant-text
               :follow-up-injected :llm-start :llm-end :assistant-text]
              (event-types log))
            (assert.are.equal "steer first" (. agent.messages 3 :content))
            (assert.are.equal "follow second" (. agent.messages 5 :content))))))

    (it "injects follow-up messages after a natural stop and continues"
      (fn []
        (let [(log on-event) (record-events)
              used {:v false}
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event
                       :get-follow-up (fn []
                                        (if used.v
                                            []
                                            (do (set used.v true)
                                                ["next task"])))})]
          (table.insert fake.responses (text-response "first done"))
          (table.insert fake.responses (text-response "second done"))
          (let [final (agent-mod.step agent "go")]
            (assert.are.equal "second done" final)
            (assert.are.same
              [:llm-start :llm-end :assistant-text
               :follow-up-injected :llm-start :llm-end :assistant-text]
              (event-types log))
            (assert.are.equal :user (. agent.messages 3 :role))
            (assert.are.equal "next task" (. agent.messages 3 :content))
            (assert.are.equal 2 (length fake.calls))))))

    (it "trips the safety cap when the model never stops"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})]
          (set fake.default-response (tool-response "loop" :noop {}))
          (let [final (agent-mod.step agent "loop forever")]
            (assert.is_truthy
              (string.find final "tool%-call loop exceeded safety cap"))
            (assert.is_true (<= (length fake.calls) agent-mod.SAFETY-CAP))
            (assert.is_true (>= (length fake.calls) agent-mod.SAFETY-CAP))
            (let [types-list (event-types log)]
              (var has-error? false)
              (each [_ t (ipairs types-list)]
                (when (= t :error) (set has-error? true)))
              (assert.is_false has-error?))))))

    (it "surfaces an error stop-reason and stops the loop"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})]
          (set fake.default-response (error-response "boom"))
          (let [final (agent-mod.step agent "hi")]
            (assert.are.equal "[error] boom" final)
            (assert.are.equal 1 (length fake.calls))
            (let [types-list (event-types log)]
              (var has-error? false)
              (each [_ t (ipairs types-list)]
                (when (= t :error) (set has-error? true)))
              (assert.is_true has-error?))))))

    (it "passes the per-agent tools to the provider as canonical Tool[]"
      (fn []
        (let [(_ on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools [{:name :custom-tool
                                :label "Custom"
                                :description "marker"
                                :parameters {:type :object}
                                :execute (fn [_]
                                           {:content [(types.text-block "")]
                                            :is-error? false})}]
                       :on-event on-event})]
          (set fake.default-response (text-response "ok"))
          (agent-mod.step agent "go")
          (let [first-call (. fake.calls 1)
                names {}]
            (each [_ d (ipairs first-call.context.tools)]
              ;; Tool descriptors are canonical; should NOT have :execute.
              (assert.is_nil d.execute)
              (tset names (tostring d.name) true))
            (assert.is_true (. names "custom-tool"))
            (assert.is_nil (. names "bash"))))))

    (it "applies convert-to-llm before sending messages to the provider"
      (fn []
        (let [(_ on-event) (record-events)
              ;; Drop messages whose role is :note (a custom AgentMessage type).
              convert (fn [msgs]
                        (let [out []]
                          (each [_ m (ipairs msgs)]
                            (when (not= m.role :note)
                              (table.insert out m)))
                          out))
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event
                       :convert-to-llm convert})]
          (table.insert agent.messages {:role :note :content "internal"})
          (set fake.default-response (text-response "ok"))
          (agent-mod.step agent "hi")
          (let [first-call (. fake.calls 1)
                roles {}]
            (each [_ m (ipairs first-call.context.messages)]
              (tset roles m.role true))
            (assert.is_nil (. roles :note))
            (assert.is_true (. roles :user)))
          (var has-note? false)
          (each [_ m (ipairs agent.messages)]
            (when (= m.role :note) (set has-note? true)))
          (assert.is_true has-note?))))

    (it "passes the system prompt through context, not as a message"
      (fn []
        (let [(_ on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :system "you are a test"
                       :tools (stub-registry "")
                       :on-event on-event})]
          (set fake.default-response (text-response "ok"))
          (agent-mod.step agent "hi")
          (let [first-call (. fake.calls 1)]
            (assert.are.equal "you are a test" first-call.context.system-prompt)
            ;; agent.messages should NOT contain a :system-role entry.
            (var has-system? false)
            (each [_ m (ipairs agent.messages)]
              (when (= m.role :system) (set has-system? true)))
            (assert.is_false has-system?)))))

    (it "dispatches by :provider-api"
      (fn []
        (let [(_ on-event) (record-events)
              agent (agent-mod.make-agent
                      {:provider-api :anthropic-messages
                       :model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})]
          (set fake.default-response (text-response "ok"))
          (agent-mod.step agent "hi")
          (assert.are.equal :anthropic-messages
                            (. fake.calls 1 :api)))))

    (it "calls on-message-append after each message append"
      (fn []
        (let [appended []
              (_ on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model "mock" :api-key :test
                       :tools (stub-registry "tool output")
                       :on-event on-event
                       :on-message-append
                       (fn [message _agent]
                         (table.insert appended message.role))})]
          (table.insert fake.responses (tool-response "call-1" :noop {}))
          (table.insert fake.responses (text-response "done"))
          (agent-mod.step agent "go")
          (assert.are.same [:user :assistant :tool-result :assistant]
                           appended))))))

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
                      {:provider-api :openai-completions
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
          ;; way `http.perform-coop` would (one yield per transfer step) so
          ;; we can assert the agent threads it all the way through.
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
              ;;   5: before tool 2 execute  ← cancel here
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
            ;; Only one tool actually executed; second was emitted as
            ;; :tool-call but cancellation fired before its execute.
            (let [types-list (event-types log)
                  tool-results 0]
              (var n 0)
              (each [_ t (ipairs types-list)]
                (when (= t :tool-result) (set n (+ n 1))))
              (assert.are.equal 1 n))
            ;; No rollback: user, tool-use assistant, completed tool result,
            ;; and an aborted assistant marker remain in history.
            (assert.are.equal 4 (length agent.messages))
            (assert.are.equal :user (. agent.messages 1 :role))
            (assert.are.equal :assistant (. agent.messages 2 :role))
            (assert.are.equal :tool-result (. agent.messages 3 :role))
            (assert.are.equal :assistant (. agent.messages 4 :role))
            (assert.are.equal :aborted (. agent.messages 4 :stop-reason))
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
