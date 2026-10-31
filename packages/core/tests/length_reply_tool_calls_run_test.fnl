;; Regression test for #606 (spec/agent-loop/FINDINGS.md): the loop dispatches on
;; content, so a :length (or other non-:tool-use) reply that carries tool calls
;; runs them and history stays provider-valid.

(local types (require :fen.core.types))

;; A fake dispatcher stands in for fen.core.llm (installed before
;; fen.core.agent is required, which binds it at load). It records the
;; messages of every request and answers from a queue.
(local fake {:calls [] :responses [] :default nil})
(fn fake.complete [api model context _options]
  (table.insert fake.calls (icollect [_ m (ipairs context.messages)] m))
  (or (table.remove fake.responses 1) fake.default
      (types.assistant-message {: api
                                :provider :test
                                : model
                                :content [(types.text-block "fallback")]
                                :stop-reason :stop})))

(tset package.loaded :fen.core.llm fake)
(local agent-mod (require :fen.core.agent))

(fn reply [content stop-reason]
  (types.assistant-message {:api :openai-completions
                            :provider :openai
                            :model :mock
                            : content
                            : stop-reason}))

(fn noop-tool [name]
  {: name
   :label name
   :description name
   :parameters {:type :object :properties {}}
   :execute (fn [_]
              {:content [(types.text-block "ok")] :is-error? false})})

(fn make-agent [opts]
  (agent-mod.make-agent (collect [k v (pairs (or opts {}))
                                  &into {:provider-name :openai
                                         :model :mock
                                         :api-key :test
                                         :tools [(noop-tool :noop)]}]
                          k
                          v)))

(fn pairing-ok? [messages]
  "The provider rule: every assistant's tool calls are answered right after
   it, in order, before anything else."
  (var pending [])
  (var ok true)
  (each [_ m (ipairs messages)]
    (if (= m.role :tool-result)
        (if (= (. pending 1) m.tool-call-id)
            (table.remove pending 1)
            (set ok false))
        (do
          (when (> (length pending) 0) (set ok false))
          (set pending (if (= m.role :assistant)
                           (icollect [_ tc (ipairs (types.assistant-tool-calls m))]
                             tc.id)
                           [])))))
  (and ok (= 0 (length pending))))

(describe "a reply that carries tool calls takes the tool path whatever its stop label (#606)"
          (fn []
            (it "runs the tool calls of a :length reply and keeps history paired"
                (fn []
                  (set fake.calls [])
                  (set fake.responses
                       [(reply [(types.text-block "partial")
                                (types.tool-call-block :c1 :noop {})]
                               :length)
                        (reply [(types.text-block "done")] :stop)])
                  (let [agent (make-agent)
                        (result outcome) (agent-mod.step agent "one")]
                    (assert.are.equal "done" result)
                    (assert.are.equal :ok outcome.status)
                    (assert.are.equal 2 (length fake.calls))
                    (assert.is_true (pairing-ok? (. fake.calls 2)))
                    (assert.are.equal :c1 (. agent.messages 3 :tool-call-id))
                    (assert.is_false (. agent.messages 3 :is-error?))
                    (agent-mod.step agent "two")
                    (assert.is_true (pairing-ok? (. fake.calls 3))))))
            (it "ends on an :error reply without running its tool calls"
                (fn []
                  (set fake.calls [])
                  (set fake.responses
                       [(reply [(types.tool-call-block :c1 :noop {})] :error)])
                  (let [agent (make-agent)
                        (result outcome) (agent-mod.step agent "one")]
                    (assert.are.equal 1 (string.find result "[error]" 1 true))
                    (assert.are.equal :error outcome.status)
                    (assert.are.equal 1 (length fake.calls))
                    (assert.are.equal :assistant
                                      (. agent.messages (length agent.messages)
                                         :role)))))))
