;; Regression test for #607 (spec/agent-loop/FINDINGS.md) and the close-turn
;; boundary (#668): malformed edit arguments are an ordinary tool error, and any
;; unwind out of the loop (crash or cancel) pairs every call left open.

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

(describe "the close-turn boundary pairs open calls on any unwind (#607)"
          (fn []
            (it "treats malformed edit arguments as an ordinary tool error"
                (fn []
                  (set fake.calls [])
                  (set fake.responses
                       [(reply [(types.tool-call-block :e1 :edit {:files [1]})
                                (types.tool-call-block :e2 :edit {:files 5})
                                (types.tool-call-block :e3 :edit 7)]
                               :tool-use)
                        (reply [(types.text-block "ok")] :stop)])
                  (let [agent (make-agent {:tools [(noop-tool :edit)]})
                        (result outcome) (agent-mod.step agent "go")]
                    (assert.are.equal "ok" result)
                    (assert.are.equal :ok outcome.status)
                    (assert.is_true (pairing-ok? agent.messages)))))
            (it "pairs every open call when the loop crashes before any result"
                (fn []
                  (set fake.calls [])
                  (set fake.responses
                       [(reply [(types.tool-call-block :k1 :noop {})
                                (types.tool-call-block :k2 :noop {})]
                               :tool-use)])
                  (let [log []
                        agent (make-agent {:tool-context (fn [_]
                                                           (error "context boom"))
                                           :on-event (fn [ev]
                                                       (table.insert log ev))})
                        (ok? err) (pcall agent-mod.step agent "go")
                        calls (icollect [_ ev (ipairs log)]
                                (when (= ev.type :tool-call) ev.id))
                        results (icollect [_ ev (ipairs log)]
                                  (when (= ev.type :tool-result) ev.id))]
                    (assert.is_false ok?)
                    (assert.truthy (string.find (tostring err) "context boom" 1
                                                true))
                    (assert.is_true (pairing-ok? agent.messages))
                    (assert.are.same [:k1 :k2] calls)
                    (assert.are.same [:k1 :k2] results)
                    (assert.truthy (string.find (. agent.messages 3 :content 1
                                                   :text)
                                                "interrupted" 1 true))
                    (assert.are.equal :error agent.outcome.status))))
            (it "pairs every open call when the step is cancelled mid-tools"
                (fn []
                  (set fake.calls [])
                  (set fake.responses
                       [(reply [(types.tool-call-block :x1 :noop {})
                                (types.tool-call-block :x2 :noop {})]
                               :tool-use)])
                  (var cancel? false)
                  (let [log []
                        agent (make-agent {:tools [{:name :noop
                                                    :label :noop
                                                    :description :noop
                                                    :parameters {:type :object
                                                                 :properties {}}
                                                    :execute (fn [_]
                                                               (set cancel?
                                                                    true)
                                                               {:content [(types.text-block "ok")]
                                                                :is-error? false})}]
                                           :on-event (fn [ev]
                                                       (table.insert log ev))})
                        co (coroutine.create (fn []
                                               (agent-mod.step agent "go"
                                                               (fn []
                                                                 cancel?))))]
                    (var ret nil)
                    (var outcome nil)
                    (while (not= (coroutine.status co) :dead)
                      (let [(ok? r o) (coroutine.resume co)]
                        (assert.is_true ok?)
                        (set ret r)
                        (set outcome o)))
                    (assert.are.equal "[cancelled]" ret)
                    (assert.are.equal :cancelled outcome.status)
                    (assert.is_true (pairing-ok? agent.messages))
                    (assert.are.equal :aborted
                                      (. agent.messages (length agent.messages)
                                         :stop-reason))
                    (let [calls (icollect [_ ev (ipairs log)]
                                  (when (= ev.type :tool-call) ev.id))]
                      (assert.are.same [:x1 :x2] calls)))))))
