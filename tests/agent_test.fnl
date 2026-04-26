;; Tests for core.agent — locks in the safety cap, event taxonomy, and the
;; tool-call → tool-result message shape we send back to OpenAI.
;;
;; Strategy: install a fake `core.llm` into package.loaded *before* requiring
;; `core.agent`. agent.fnl does `(local llm (require :core.llm))` at module
;; load, so the first require resolves to our fake. Each test resets the
;; fake's state via `fake.reset`.

(local fake
  {:calls []
   :responses []                             ; queue: shift one per call
   :default-response nil                     ; if responses empty, use this
   :build-request (fn [opts] opts)           ; identity — tests can inspect
   :reset (fn [self]
            (set self.calls [])
            (set self.responses [])
            (set self.default-response nil))})

(fn shallow-copy [t]
  (let [out []]
    (each [_ v (ipairs t)] (table.insert out v))
    out))

(fn fake.call-openai [_api-key request]
  ;; Snapshot the request — agent.messages is mutated in place across
  ;; iterations, so without a copy a recorded call drifts as the loop runs.
  (table.insert fake.calls
                {:model request.model
                 :max_tokens request.max_tokens
                 :tools request.tools
                 :tool_choice request.tool_choice
                 :messages (shallow-copy request.messages)})
  (let [r (table.remove fake.responses 1)]
    (or r fake.default-response
        {:ok? true :finish-reason :stop
         :message {:role :assistant :content "fallback"}
         :usage {}})))

(tset package.loaded :core.llm fake)

(local agent-mod (require :core.agent))

(fn make-text-response [text]
  {:ok? true :finish-reason :stop
   :message {:role :assistant :content text}
   :usage {}})

(fn make-tool-response [id name args]
  {:ok? true :finish-reason :tool_calls
   :message {:role :assistant
             :content nil
             :tool_calls [{:id id
                           :type :function
                           :function {: name :arguments args}}]}
   :usage {}})

(fn record-events []
  (let [log []]
    (values log (fn [ev] (table.insert log ev)))))

(fn event-types [log]
  (let [out []]
    (each [_ ev (ipairs log)] (table.insert out ev.type))
    out))

;; A registry whose tools all return a fixed string. Lets us assert event flow
;; without depending on real bash/read/write side effects.
(fn stub-registry [output]
  {:noop {:description "no-op"
          :parameters {:type :object :properties {}}
          :execute (fn [_] {:ok? true :output output})}})

(describe "core.agent.step"
  (fn []
    (before_each (fn [] (fake:reset)))

    (it "stops after one turn when the model returns a final text"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model :gpt-4o-mini :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})]
          (set fake.default-response (make-text-response "hello"))
          (let [final (agent-mod.step agent "hi")]
            (assert.are.equal "hello" final)
            (assert.are.equal 1 (length fake.calls))
            (assert.are.same [:llm-start :llm-end :assistant-text]
                             (event-types log))))))

    (it "executes tool calls then continues until a stop"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model :gpt-4o-mini :api-key :test
                       :tools (stub-registry "tool ran")
                       :on-event on-event})]
          (table.insert fake.responses (make-tool-response :call-1 :noop "{}"))
          (table.insert fake.responses (make-text-response "done"))
          (let [final (agent-mod.step agent "use a tool")]
            (assert.are.equal "done" final)
            (assert.are.equal 2 (length fake.calls))
            (assert.are.same
              [:llm-start :llm-end :tool-call :tool-result
               :llm-start :llm-end :assistant-text]
              (event-types log))))))

    (it "appends a {role:tool tool_call_id} message after each tool execution"
      (fn []
        (let [(_ on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model :gpt-4o-mini :api-key :test
                       :tools (stub-registry "tool output")
                       :on-event on-event})]
          (table.insert fake.responses (make-tool-response :call-xyz :noop "{}"))
          (table.insert fake.responses (make-text-response "ok"))
          (agent-mod.step agent "go")
          ;; Find the tool message in agent.messages.
          (var tool-msg nil)
          (each [_ m (ipairs agent.messages)]
            (when (= m.role :tool) (set tool-msg m)))
          (assert.is_table tool-msg)
          (assert.are.equal :call-xyz tool-msg.tool_call_id)
          (assert.are.equal "tool output" tool-msg.content))))

    (it "trips the 16-turn safety cap when the model never stops"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model :gpt-4o-mini :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})]
          ;; Default response returns tool_calls forever.
          (set fake.default-response (make-tool-response :loop :noop "{}"))
          (let [final (agent-mod.step agent "loop forever")]
            (assert.is_truthy
              (string.find final "tool%-call loop exceeded safety cap"))
            ;; The cap is 16; we should NOT have called more than that.
            (assert.is_true (<= (length fake.calls) 16))
            ;; Sanity: it actually ran near the cap, not just bailed early.
            (assert.is_true (>= (length fake.calls) 16))
            ;; Cap triggers a warn but no :error event (only HTTP errors emit one).
            (assert.is_falsy
              (let [types (event-types log)
                    found? false]
                (each [_ t (ipairs types)]
                  (when (= t :error) (lua "found_3f = true")))
                found?))))))

    (it "surfaces an HTTP/transport error and stops the loop"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model :gpt-4o-mini :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})]
          (set fake.default-response {:ok? false :error "boom"})
          (let [final (agent-mod.step agent "hi")]
            (assert.are.equal "[error] boom" final)
            (assert.are.equal 1 (length fake.calls))
            (let [types (event-types log)
                  has-error? (do
                               (var f false)
                               (each [_ t (ipairs types)]
                                 (when (= t :error) (set f true)))
                               f)]
              (assert.is_true has-error?))))))

    (it "uses the per-agent tools override when building requests"
      (fn []
        (let [(_ on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model :gpt-4o-mini :api-key :test
                       :tools {:custom-tool
                               {:description "marker"
                                :parameters {:type :object}
                                :execute (fn [_] {:ok? true :output ""})}}
                       :on-event on-event})]
          (set fake.default-response (make-text-response "ok"))
          (agent-mod.step agent "go")
          (let [last-req (. fake.calls 1)
                names {}]
            (each [_ d (ipairs last-req.tools)]
              (tset names d.function.name true))
            (assert.is_true (. names :custom-tool))
            (assert.is_nil (. names :bash))))))

    ;; Mirrors pi-mono's `convertToLlm` indirection
    ;; (packages/agent/src/agent-loop.ts:254): the agent can carry custom
    ;; message shapes in its history and project them on the way out.
    (it "applies convert-to-llm before sending messages to build-request"
      (fn []
        (let [(_ on-event) (record-events)
              ;; Drop any message whose role is :note (a custom non-LLM type).
              convert (fn [msgs]
                        (let [out []]
                          (each [_ m (ipairs msgs)]
                            (when (not= m.role :note)
                              (table.insert out m)))
                          out))
              agent (agent-mod.make-agent
                      {:model :gpt-4o-mini :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event
                       :convert-to-llm convert})]
          ;; Inject a custom message before stepping; convert-to-llm should
          ;; strip it from what reaches the model, but it stays in agent.messages.
          (table.insert agent.messages {:role :note :content "internal"})
          (set fake.default-response (make-text-response "ok"))
          (agent-mod.step agent "hi")
          (let [sent (. fake.calls 1)
                roles {}]
            (each [_ m (ipairs sent.messages)]
              (tset roles m.role true))
            (assert.is_nil (. roles :note))
            (assert.is_true (. roles :user)))
          ;; The original list still carries the note — only the wire view drops it.
          (var has-note? false)
          (each [_ m (ipairs agent.messages)]
            (when (= m.role :note) (set has-note? true)))
          (assert.is_true has-note?))))

    (it "defaults convert-to-llm to identity when caller omits it"
      (fn []
        (let [(_ on-event) (record-events)
              agent (agent-mod.make-agent
                      {:model :gpt-4o-mini :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event})]
          (set fake.default-response (make-text-response "ok"))
          (agent-mod.step agent "hi")
          ;; The user message we just inserted should have made it through.
          (let [sent (. fake.calls 1)]
            (assert.are.equal "hi" (. sent.messages (length sent.messages) :content))))))))
