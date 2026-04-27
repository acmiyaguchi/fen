;; Tests for core.agent — locks the safety cap, event taxonomy, canonical
;; message shape, and provider dispatch.
;;
;; Strategy: install a fake `core.llm` into package.loaded *before* requiring
;; `core.agent`. agent.fnl does `(local llm (require :core.llm))` at module
;; load, so the first require resolves to our fake.

(local types (require :core.types))

(local fake
  {:calls []
   :responses []
   :default-response nil
   ;; The dispatcher we replace exposes `complete`. Tests queue or set
   ;; canonical AssistantMessages as responses.
   :reset (fn [self]
            (set self.calls [])
            (set self.responses [])
            (set self.default-response nil))})

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

(fn fake.complete [api model context options]
  (table.insert fake.calls (snapshot-context api model context options))
  (let [r (table.remove fake.responses 1)]
    (or r fake.default-response
        (types.assistant-message
          {:api api :provider :test :model model
           :content [(types.text-block "fallback")]
           :stop-reason :stop}))))

(tset package.loaded :core.llm fake)

(local agent-mod (require :core.agent))

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
                            (. fake.calls 1 :api)))))))

(fn drain-coop [agent user-msg]
  "Run step-coop to completion, counting how many times it yields. Used to
   prove the coroutine actually releases control between phases rather
   than running straight through."
  (let [co (coroutine.create (fn [] (agent-mod.step-coop agent user-msg)))]
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

(describe "core.agent.step-coop"
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
              (assert.is_true has-error?))))))))
