(local json (require :fen.util.json))

(describe "json presenter"
  (fn []
    (it "writes a structured result blob with usage and stop-reason"
      (fn []
        (let [old-agent (. package.loaded "fen.core.agent")
              old-lifecycle (. package.loaded "fen.turn_lifecycle")
              out-path (os.tmpname)
              emitted []
              messages [{:role :user :content "say hello"}
                        {:role :assistant
                         :content [{:type :text :text "hello"}]
                         :usage {:input 5 :output 2 :total-tokens 7}
                         :stop-reason :stop}]]
          (tset package.loaded "fen.extensions.json" nil)
          (tset package.loaded "fen.core.agent"
                {:step (fn [agent prompt]
                         (assert.are.equal "say hello" prompt)
                         (assert.are.equal :agent agent.name)
                         "hello")})
          (tset package.loaded "fen.turn_lifecycle"
                {:emit-complete! (fn [_state ok? result]
                                   (table.insert emitted {:ok? ok? :result result}))})
          (let [(ok? result) (xpcall
                            #(let [p (require :fen.extensions.json)]
                               (p.run {:state {:agent {:name :agent
                                                       :messages messages}
                                               :opts {:print "say hello"
                                                      :json-output-file out-path}}}))
                            debug.traceback)]
            (tset package.loaded "fen.extensions.json" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            (when (not ok?) (error result))
            (assert.are.equal 0 result))
          (assert.are.equal 1 (length emitted))
          (assert.is_true (. emitted 1 :ok?))
          (let [f (assert (io.open out-path :r))
                text (f:read :*a)]
            (f:close)
            (os.remove out-path)
            (let [blob (json.decode text)]
              (assert.are.equal "hello" blob.final-text)
              (assert.are.equal "stop" blob.stop-reason)
              (assert.are.equal 7 (. blob :usage :total-tokens))
              (assert.are.equal 2 (length blob.messages))
              (assert.is_nil blob.error))))))

    (it "sums usage across every assistant message in the turn"
      (fn []
        (let [old-agent (. package.loaded "fen.core.agent")
              old-lifecycle (. package.loaded "fen.turn_lifecycle")
              out-path (os.tmpname)
              messages [{:role :user :content "go"}
                        {:role :assistant
                         :content [{:type :text :text "step 1"}]
                         :usage {:input 5 :output 2 :total-tokens 7}
                         :stop-reason :tool-use}
                        {:role :assistant
                         :content [{:type :text :text "done"}]
                         :usage {:input 3 :output 4 :total-tokens 7}
                         :stop-reason :stop}]]
          (tset package.loaded "fen.extensions.json" nil)
          (tset package.loaded "fen.core.agent" {:step (fn [_ _] "done")})
          (tset package.loaded "fen.turn_lifecycle"
                {:emit-complete! (fn [_ _ _] nil)})
          (let [(ok? result) (xpcall
                            #(let [p (require :fen.extensions.json)]
                               (p.run {:state {:agent {:name :agent
                                                       :messages messages}
                                               :opts {:print "go"
                                                      :json-output-file out-path}}}))
                            debug.traceback)]
            (tset package.loaded "fen.extensions.json" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            (when (not ok?) (error result)))
          (let [f (assert (io.open out-path :r))
                text (f:read :*a)]
            (f:close)
            (os.remove out-path)
            (let [blob (json.decode text)]
              (assert.are.equal 14 (. blob :usage :total-tokens))
              (assert.are.equal 8 (. blob :usage :input))
              (assert.are.equal 6 (. blob :usage :output)))))))

    (it "reports a provider-error turn as an error and returns a non-zero exit code"
      (fn []
        (let [old-agent (. package.loaded "fen.core.agent")
              old-lifecycle (. package.loaded "fen.turn_lifecycle")
              out-path (os.tmpname)
              ;; agent.step records provider errors as stop-reason :error instead of raising; must count as failure.
              messages [{:role :user :content "go"}
                        {:role :assistant
                         :content [{:type :text :text "[error] boom"}]
                         :stop-reason :error}]]
          (tset package.loaded "fen.extensions.json" nil)
          (tset package.loaded "fen.core.agent"
                {:step (fn [_ _] "[error] boom")})
          (tset package.loaded "fen.turn_lifecycle"
                {:emit-complete! (fn [_ _ _] nil)})
          (let [(ok? result) (xpcall
                            #(let [p (require :fen.extensions.json)]
                               (p.run {:state {:agent {:name :agent
                                                       :messages messages}
                                               :opts {:print "go"
                                                      :json-output-file out-path}}}))
                            debug.traceback)]
            (tset package.loaded "fen.extensions.json" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            (when (not ok?) (error result))
            (assert.are.equal 1 result))
          (let [f (assert (io.open out-path :r))
                text (f:read :*a)]
            (f:close)
            (os.remove out-path)
            (let [blob (json.decode text)]
              (assert.are.equal "error" blob.stop-reason)
              (assert.is_nil blob.final-text)
              (assert.is_truthy (string.find (tostring blob.error) "boom" 1 true)))))))

    (it "reports a turn with no final assistant reply as an error"
      (fn []
        (let [old-agent (. package.loaded "fen.core.agent")
              old-lifecycle (. package.loaded "fen.turn_lifecycle")
              out-path (os.tmpname)
              ;; A final :tool-use means safety-cap exhaustion, not a natural stop.
              messages [{:role :user :content "go"}
                        {:role :assistant
                         :content [{:type :tool-call :name "noop"}]
                         :stop-reason :tool-use}]]
          (tset package.loaded "fen.extensions.json" nil)
          (tset package.loaded "fen.core.agent"
                {:step (fn [_ _] "[error] tool-call loop exceeded safety cap")})
          (tset package.loaded "fen.turn_lifecycle"
                {:emit-complete! (fn [_ _ _] nil)})
          (let [(ok? result) (xpcall
                            #(let [p (require :fen.extensions.json)]
                               (p.run {:state {:agent {:name :agent
                                                       :messages messages}
                                               :opts {:print "go"
                                                      :json-output-file out-path}}}))
                            debug.traceback)]
            (tset package.loaded "fen.extensions.json" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            (when (not ok?) (error result))
            (assert.are.equal 1 result))
          (let [f (assert (io.open out-path :r))
                text (f:read :*a)]
            (f:close)
            (os.remove out-path)
            (let [blob (json.decode text)]
              (assert.are.equal "tool-use" blob.stop-reason)
              (assert.is_nil blob.final-text)
              (assert.is_truthy
                (string.find (tostring blob.error) "safety cap" 1 true)))))))

    (it "replays a subagent transcript and records new messages to it"
      (fn []
        (let [old-agent (. package.loaded "fen.core.agent")
              old-lifecycle (. package.loaded "fen.turn_lifecycle")
              events (require :fen.core.extensions.events)
              sub-events (require :fen.extensions.subagent.events)
              out-path (os.tmpname)
              transcript-path (os.tmpname)
              seen []
              prior [{:role :user :content "original task"}
                     {:role :assistant
                      :content [{:type :tool-call :id "c1" :name "read"
                                 :arguments {:path "x"}}]
                      :usage {:input 100 :output 50 :total-tokens 150}
                      :stop-reason :tool-use}
                     {:role :tool-result :tool-call-id "c1" :tool-name "read"
                      :content [{:type :text :text "EVIDENCE-42"}]
                      :is-error? false}]]
          (each [_ m (ipairs prior)]
            (assert (sub-events.append-transcript-message! transcript-path m)))
          (tset package.loaded "fen.extensions.json" nil)
          (tset package.loaded "fen.core.agent"
                {:step (fn [agent prompt]
                         (each [_ m (ipairs agent.messages)]
                           (table.insert seen m))
                         (each [_ m (ipairs [{:role :user :content prompt}
                                             {:role :assistant
                                              :content [{:type :text :text "final"}]
                                              :usage {:input 7 :output 3 :total-tokens 10}
                                              :stop-reason :stop}])]
                           (table.insert agent.messages m)
                           (events.emit {:type :message-appended :agent agent
                                         :message m
                                         :index (length agent.messages)}))
                         "final")})
          (tset package.loaded "fen.turn_lifecycle"
                {:emit-complete! (fn [_ _ _] nil)})
          (let [(ok? result) (xpcall
                               #(let [p (require :fen.extensions.json)]
                                  (p.run {:state {:agent {:name :agent :messages []}
                                                  :opts {:print "finalize now"
                                                         :json-output-file out-path
                                                         :subagent-transcript-file transcript-path}}}))
                               debug.traceback)]
            (tset package.loaded "fen.extensions.json" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            (when (not ok?) (error result))
            (assert.are.equal 0 result))
          ;; The agent loop started from the replayed canonical history.
          (assert.are.equal 3 (length seen))
          (assert.are.equal "EVIDENCE-42" (. seen 3 :content 1 :text))
          (let [f (assert (io.open out-path :r))
                blob (json.decode (f:read :*a))]
            (f:close)
            (os.remove out-path)
            ;; Earlier attempts' usage is accounted by the parent already.
            (assert.are.equal 10 (. blob :usage :total-tokens))
            (assert.are.equal 2 (length blob.messages))
            (assert.are.equal "final" blob.final-text))
          ;; New messages were appended so a later restart can resume them.
          (let [(read stats) (sub-events.read-transcript transcript-path)]
            (os.remove transcript-path)
            (assert.are.equal 0 stats.malformed)
            (assert.are.equal 5 (length read))
            (assert.are.equal "finalize now" (. read 4 :content))))))))
