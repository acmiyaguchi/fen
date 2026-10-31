;; Regression test for #609 (spec/agent-loop/FINDINGS.md): a refused-twice turn
;; returns an :error Outcome, and turn_lifecycle reports it instead of guessing
;; from the last message (a tool result).

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

(local lifecycle (require :fen.turn_lifecycle))

(describe "a refused-twice turn reports :error (#609)"
          (fn []
            (it "returns an :error Outcome that the turn lifecycle reports"
                (fn []
                  (set fake.calls [])
                  (set fake.responses
                       [(reply [(types.tool-call-block :r1 :noop {})] :tool-use)
                        (reply [(types.tool-call-block :r2 :noop {})] :tool-use)])
                  (let [log []
                        agent (make-agent {:on-event (fn [ev]
                                                       (table.insert log ev))})
                        (result outcome) (agent-mod.step agent "go" nil
                                                         {:tool-choice :none})
                        errors (icollect [_ ev (ipairs log)]
                                 (when (= ev.type :error) ev))
                        ev (lifecycle.complete-event {: agent} true result)]
                    (assert.are.equal 1 (string.find result "[error]" 1 true))
                    (assert.are.equal :error outcome.status)
                    (assert.are.equal outcome agent.outcome)
                    (assert.are.equal 1 (length errors))
                    (assert.is_true (pairing-ok? agent.messages))
                    (assert.are.equal :tool-result
                                      (. agent.messages (length agent.messages)
                                         :role))
                    (assert.are.equal :error ev.status)
                    (assert.are.equal "model called tools while tool-choice is none"
                                      ev.error))))
            (it "keeps a text answer after one refusal :ok"
                (fn []
                  (set fake.calls [])
                  (set fake.responses
                       [(reply [(types.tool-call-block :r1 :noop {})] :tool-use)
                        (reply [(types.text-block "answer")] :stop)])
                  (let [agent (make-agent)
                        (result outcome) (agent-mod.step agent "go" nil
                                                         {:tool-choice :none})
                        ev (lifecycle.complete-event {: agent} true result)]
                    (assert.are.equal "answer" result)
                    (assert.are.equal :ok outcome.status)
                    (assert.are.equal :ok ev.status)
                    (assert.are.equal "answer" ev.result))))))
