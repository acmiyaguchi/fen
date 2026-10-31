;; Probe for #608 (spec/agent-loop/FINDINGS.md): An empty queued follow-up makes the loop call the provider again on its own reply.
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

(describe "#608 empty queued follow-up"
          (fn []
            (it "sends a request that ends on the assistant's own reply"
                (fn []
                  (known-bug 608
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
                                                                               [""])))})]
                                 (agent-mod.step agent "hi")
                                 (let [second (. fake.calls 2)]
                                   (and second
                                        (= :assistant
                                           (. second (length second) :role)))))))))))
