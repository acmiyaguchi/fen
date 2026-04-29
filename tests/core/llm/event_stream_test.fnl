(local event-stream (require :core.llm.event_stream))
(local llm (require :core.llm))
(local types (require :core.types))

(describe "core.llm.event_stream"
  (fn []
    (it "records events and exposes the terminal result"
      (fn []
        (let [seen []
              stream (event-stream.new-stream #(table.insert seen $1))
              asst (types.assistant-message
                     {:api :test-stream :provider :test :model "m"
                      :content [(types.text-block "ok")]
                      :stop-reason :stop})]
          (stream.push {:type :start})
          (stream.push {:type :done :message asst})
          (stream.push {:type :text-delta :delta "ignored-after-done"})
          (assert.are.equal 2 (length stream.events))
          (assert.are.equal 2 (length seen))
          (assert.is_true (stream.done?))
          (assert.are.equal asst (stream.result)))))

    (it "does not let end overwrite a terminal event result"
      (fn []
        (let [stream (event-stream.new-stream)
              asst (types.assistant-message
                     {:api :test-stream :provider :test :model "m"
                      :content [(types.text-block "ok")]
                      :stop-reason :stop})
              other (types.assistant-message
                      {:api :test-stream :provider :test :model "m"
                       :content [(types.text-block "other")]
                       :stop-reason :stop})]
          (stream.push {:type :done :message asst})
          (stream.end other)
          (assert.are.equal asst (stream.result)))))))

(describe "core.llm.emit-block-events"
  (fn []
    (it "lets a non-streaming provider synthesize block events from a final message"
      (fn []
        ;; A provider that can't stream natively still satisfies the
        ;; on-event contract by synthesizing block events from the final
        ;; AssistantMessage. emit-block-events is the helper they use.
        (let [api :test-stream-fallback
              asst (types.assistant-message
                     {:api api :provider :test :model "m"
                      :content [(types.text-block "hello")]
                      :usage {:input 1 :output 2 :cache-read 0 :cache-write 0 :total-tokens 3}
                      :stop-reason :stop})
              calls []]
          (llm.register
            {:api api
             :provider :test
             :complete (fn [model context options ?on-event ?yield-fn]
                         (table.insert calls {:model model
                                              :context context
                                              :options options
                                              :has-on-event? (not= ?on-event nil)
                                              :has-yield? (not= ?yield-fn nil)})
                         (when ?on-event (llm.emit-block-events asst ?on-event))
                         asst)})
          (let [events []
                result (llm.complete api "m" {:messages []} {:max-tokens 7}
                                     #(table.insert events $1)
                                     (fn [] nil))]
            (assert.are.equal asst result)
            (assert.are.equal 1 (length calls))
            (assert.is_true (. calls 1 :has-on-event?))
            (assert.is_true (. calls 1 :has-yield?))
            (assert.are.equal :start (. events 1 :type))
            (assert.are.equal :text-start (. events 2 :type))
            (assert.are.equal :text-delta (. events 3 :type))
            (assert.are.equal "hello" (. events 3 :delta))
            (assert.are.equal :text-end (. events 4 :type))
            (assert.are.equal :done (. events 5 :type))
            (assert.are.equal asst (. events 5 :message))))))))
