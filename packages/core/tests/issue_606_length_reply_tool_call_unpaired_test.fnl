;; Probe for #606 (spec/agent-loop/FINDINGS.md): A `:length` reply that carries a tool call takes the natural-stop path, so the call is never answered and the next request is invalid.
;; Passes while the bug reproduces against the real agent loop; the fix turns
;; it into a regular test of the correct behaviour.

(local types (require :fen.core.types))
(local {: known-bug} (require :fen.testing))

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

(describe "#606 :length reply with a tool call"
          (fn []
            (it "leaves the call unanswered in the next request"
                (fn []
                  (known-bug 606
                             (fn []
                               (set fake.calls [])
                               (set fake.responses
                                    [(reply [(types.text-block "partial")
                                             (types.tool-call-block :c1 :noop
                                                                    {})]
                                            :length)])
                               (let [agent (make-agent)]
                                 (agent-mod.step agent "one")
                                 (agent-mod.step agent "two")
                                 (not (pairing-ok? (. fake.calls 2))))))))))
