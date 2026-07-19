(local json (require :fen.util.json))

(describe "json presenter"
  (fn []
    (it "writes a structured result blob with usage and stop-reason"
      (fn []
        (let [old-agent (. package.loaded "fen.core.agent")
              old-lifecycle (. package.loaded "fen.turn_lifecycle")
              out-path (os.tmpname)
              emitted []
              ;; Seed the agent message log the way agent.step would leave it:
              ;; a user turn plus an assistant message carrying usage + stop.
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
          (let [(ok? err) (xpcall
                            #(let [p (require :fen.extensions.json)]
                               (p.run {:state {:agent {:name :agent
                                                       :messages messages}
                                               :opts {:print "say hello"
                                                      :json-output-file out-path}}}))
                            debug.traceback)]
            (tset package.loaded "fen.extensions.json" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            (when (not ok?) (error err)))
          ;; emit-complete! fired once, successfully.
          (assert.are.equal 1 (length emitted))
          (assert.is_true (. emitted 1 :ok?))
          ;; The blob on disk decodes to the expected structure.
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
              ;; A tool-using turn: two provider calls, each its own assistant
              ;; message with per-call usage. The blob must reflect the sum.
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
          (let [(ok? err) (xpcall
                            #(let [p (require :fen.extensions.json)]
                               (p.run {:state {:agent {:name :agent
                                                       :messages messages}
                                               :opts {:print "go"
                                                      :json-output-file out-path}}}))
                            debug.traceback)]
            (tset package.loaded "fen.extensions.json" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            (when (not ok?) (error err)))
          (let [f (assert (io.open out-path :r))
                text (f:read :*a)]
            (f:close)
            (os.remove out-path)
            (let [blob (json.decode text)]
              (assert.are.equal 14 (. blob :usage :total-tokens))
              (assert.are.equal 8 (. blob :usage :input))
              (assert.are.equal 6 (. blob :usage :output)))))))

    (it "reports a provider-error turn as an error and exits non-zero"
      (fn []
        (let [old-agent (. package.loaded "fen.core.agent")
              old-lifecycle (. package.loaded "fen.turn_lifecycle")
              old-exit os.exit
              out-path (os.tmpname)
              exit-codes []
              ;; agent.step does NOT raise on a provider error: it sets
              ;; stop-reason :error and returns "[error] ...". The presenter
              ;; must treat that as a failure, not a clean result.
              messages [{:role :user :content "go"}
                        {:role :assistant
                         :content [{:type :text :text "[error] boom"}]
                         :stop-reason :error}]]
          (set os.exit (fn [code] (table.insert exit-codes code)))
          (tset package.loaded "fen.extensions.json" nil)
          (tset package.loaded "fen.core.agent"
                {:step (fn [_ _] "[error] boom")})
          (tset package.loaded "fen.turn_lifecycle"
                {:emit-complete! (fn [_ _ _] nil)})
          (let [(ok? err) (xpcall
                            #(let [p (require :fen.extensions.json)]
                               (p.run {:state {:agent {:name :agent
                                                       :messages messages}
                                               :opts {:print "go"
                                                      :json-output-file out-path}}}))
                            debug.traceback)]
            (set os.exit old-exit)
            (tset package.loaded "fen.extensions.json" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            (when (not ok?) (error err)))
          ;; Exited 1 exactly once for the failed turn.
          (assert.are.equal 1 (length exit-codes))
          (assert.are.equal 1 (. exit-codes 1))
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
              old-exit os.exit
              out-path (os.tmpname)
              exit-codes []
              ;; A final :tool-use means the agent exhausted its safety cap
              ;; before receiving a natural stop from the model.
              messages [{:role :user :content "go"}
                        {:role :assistant
                         :content [{:type :tool-call :name "noop"}]
                         :stop-reason :tool-use}]]
          (set os.exit (fn [code] (table.insert exit-codes code)))
          (tset package.loaded "fen.extensions.json" nil)
          (tset package.loaded "fen.core.agent"
                {:step (fn [_ _] "[error] tool-call loop exceeded safety cap")})
          (tset package.loaded "fen.turn_lifecycle"
                {:emit-complete! (fn [_ _ _] nil)})
          (let [(ok? err) (xpcall
                            #(let [p (require :fen.extensions.json)]
                               (p.run {:state {:agent {:name :agent
                                                       :messages messages}
                                               :opts {:print "go"
                                                      :json-output-file out-path}}}))
                            debug.traceback)]
            (set os.exit old-exit)
            (tset package.loaded "fen.extensions.json" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            (when (not ok?) (error err)))
          (assert.are.equal 1 (length exit-codes))
          (assert.are.equal 1 (. exit-codes 1))
          (let [f (assert (io.open out-path :r))
                text (f:read :*a)]
            (f:close)
            (os.remove out-path)
            (let [blob (json.decode text)]
              (assert.are.equal "tool-use" blob.stop-reason)
              (assert.is_nil blob.final-text)
              (assert.is_truthy
                (string.find (tostring blob.error) "safety cap" 1 true)))))))))
