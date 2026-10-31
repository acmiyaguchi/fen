;; Regression test for #610 (spec/agent-loop/FINDINGS.md): hitting the safety
;; cap emits :error and ends the step with an :error Outcome (runs the real
;; 1000-turn cap against a fake dispatcher).

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

(describe "the safety cap is an ordinary error exit (#610)"
          (fn []
            (it "emits :error and reports an :error Outcome"
                (fn []
                  (set fake.calls [])
                  (set fake.responses [])
                  (set fake.default
                       (reply [(types.tool-call-block :loop :noop {})]
                              :tool-use))
                  (let [log []
                        agent (make-agent {:on-event (fn [ev]
                                                       (table.insert log ev))})
                        (result outcome) (agent-mod.step agent "go")
                        errors (icollect [_ ev (ipairs log)]
                                 (when (= ev.type :error) ev))
                        ev (lifecycle.emit-complete! {: agent} true result)]
                    (set fake.default nil)
                    (assert.are.equal agent-mod.SAFETY-CAP (length fake.calls))
                    (assert.are.equal "[error] tool-call loop exceeded safety cap"
                                      result)
                    (assert.are.equal :error outcome.status)
                    (assert.are.equal 1 (length errors))
                    (assert.are.equal "tool-call loop exceeded safety cap"
                                      (. errors 1 :error))
                    (assert.are.equal :error ev.status)
                    (assert.are.equal "tool-call loop exceeded safety cap"
                                      ev.error)
                    ;; emit-complete! consumes the Outcome.
                    (assert.is_nil agent.outcome))))))
