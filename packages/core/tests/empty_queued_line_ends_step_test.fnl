;; Regression test for #608 (spec/agent-loop/FINDINGS.md): the loop continues
;; after a natural stop only when a queued line was actually appended.

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

(describe "an empty queued line does not continue the loop (#608)"
          (fn []
            (it "ends the step at a natural stop when only empty lines are queued"
                (fn []
                  (set fake.calls [])
                  (set fake.responses
                       [(reply [(types.text-block "answer")] :stop)
                        (reply [(types.text-block "again")] :stop)])
                  (var served? false)
                  (let [agent (make-agent {:get-follow-up (fn []
                                                            (if served?
                                                                []
                                                                (do
                                                                  (set served?
                                                                       true)
                                                                  [""])))})
                        (result outcome) (agent-mod.step agent "hi")]
                    (assert.are.equal "answer" result)
                    (assert.are.equal :ok outcome.status)
                    (assert.are.equal 1 (length fake.calls)))))
            (it "polls follow-ups when steering drained only empty lines"
                (fn []
                  (set fake.calls [])
                  (set fake.responses
                       [(reply [(types.text-block "answer")] :stop)
                        (reply [(types.text-block "follow answer")] :stop)])
                  (var steered? false)
                  (var followed? false)
                  (let [agent (make-agent {:get-steering (fn []
                                                           (if steered? []
                                                               (do
                                                                 (set steered?
                                                                      true)
                                                                 [""])))
                                           :get-follow-up (fn []
                                                            (if followed? []
                                                                (do
                                                                  (set followed?
                                                                       true)
                                                                  ["more"])))})
                        result (agent-mod.step agent "hi")
                        second (. fake.calls 2)]
                    (assert.are.equal "follow answer" result)
                    (assert.are.equal :user (. second (length second) :role)))))))
