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
              (assert.is_nil blob.error))))))))
