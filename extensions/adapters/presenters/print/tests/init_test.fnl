(describe "print presenter"
  (fn []
    (it "steps the agent directly so --print text is never slash-dispatched"
      (fn []
        (let [old-agent (. package.loaded "fen.core.agent")
              old-lifecycle (. package.loaded "fen.turn_lifecycle")
              old-print _G.print
              lines []
              emitted []]
          (tset package.loaded "fen.extensions.print" nil)
          (tset package.loaded "fen.core.agent"
                {:step (fn [agent prompt]
                         (assert.are.equal :agent agent.name)
                         (assert.are.equal "/literal prompt" prompt)
                         (table.insert agent.messages {:role :assistant
                                                       :stop-reason :stop})
                         "ok")})
          (tset package.loaded "fen.turn_lifecycle"
                {:emit-complete! (fn [state ok? result]
                                   (table.insert emitted {:state state
                                                          :ok? ok?
                                                          :result result}))})
          (set _G.print (fn [line] (table.insert lines line)))
          (let [(ok? err) (xpcall
                            #(let [print-presenter (require :fen.extensions.print)]
                               (print-presenter.run
                                 {:state {:agent {:name :agent :messages []}
                                          :opts {:print "/literal prompt"}}}))
                            debug.traceback)]
            (set _G.print old-print)
            (tset package.loaded "fen.extensions.print" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            (when (not ok?) (error err)))
          (assert.are.same ["ok"] lines)
          (assert.are.equal 1 (length emitted))
          (assert.is_true (. emitted 1 :ok?))
          (assert.are.equal "ok" (. emitted 1 :result)))))

    (it "exits non-zero and prints nothing to stdout on a provider-error turn"
      (fn []
        (let [old-agent (. package.loaded "fen.core.agent")
              old-lifecycle (. package.loaded "fen.turn_lifecycle")
              old-print _G.print
              old-exit os.exit
              lines []
              emitted []
              exit-codes []
              ;; agent.step does NOT raise on a provider/HTTP error: it records
              ;; stop-reason :error on the last assistant message and returns
              ;; "[error] ...". The presenter must treat that as a failed turn.
              messages [{:role :user :content "go"}
                        {:role :assistant
                         :content [{:type :text :text "[error] HTTP 400"}]
                         :stop-reason :error}]]
          (set os.exit (fn [code] (table.insert exit-codes code)))
          (tset package.loaded "fen.extensions.print" nil)
          (tset package.loaded "fen.core.agent"
                {:step (fn [_ _] "[error] HTTP 400")})
          (tset package.loaded "fen.turn_lifecycle"
                {:emit-complete! (fn [_state ok? result]
                                   (table.insert emitted {:ok? ok? :result result}))})
          (set _G.print (fn [line] (table.insert lines line)))
          (let [(ok? err) (xpcall
                            #(let [print-presenter (require :fen.extensions.print)]
                               (print-presenter.run
                                 {:state {:agent {:name :agent
                                                  :messages messages}
                                          :opts {:print "go"}}}))
                            debug.traceback)]
            (set _G.print old-print)
            (set os.exit old-exit)
            (tset package.loaded "fen.extensions.print" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            (when (not ok?) (error err)))
          ;; Exited 1 exactly once for the failed turn, and printed no reply.
          (assert.are.equal 1 (length exit-codes))
          (assert.are.equal 1 (. exit-codes 1))
          (assert.are.same [] lines)
          ;; The turn-complete lifecycle event still fired.
          (assert.are.equal 1 (length emitted)))))

    (it "exits non-zero when the turn ends without a final assistant reply"
      (fn []
        (let [old-agent (. package.loaded "fen.core.agent")
              old-lifecycle (. package.loaded "fen.turn_lifecycle")
              old-print _G.print
              old-exit os.exit
              lines []
              exit-codes []
              ;; A final :tool-use means the agent exhausted its safety cap
              ;; before receiving a natural stop from the model.
              messages [{:role :user :content "go"}
                        {:role :assistant
                         :content [{:type :tool-call :name "noop"}]
                         :stop-reason :tool-use}]]
          (set os.exit (fn [code] (table.insert exit-codes code)))
          (tset package.loaded "fen.extensions.print" nil)
          (tset package.loaded "fen.core.agent"
                {:step (fn [_ _] "[error] tool-call loop exceeded safety cap")})
          (tset package.loaded "fen.turn_lifecycle"
                {:emit-complete! (fn [_ _ _] nil)})
          (set _G.print (fn [line] (table.insert lines line)))
          (let [(ok? err) (xpcall
                            #(let [print-presenter (require :fen.extensions.print)]
                               (print-presenter.run
                                 {:state {:agent {:name :agent
                                                  :messages messages}
                                          :opts {:print "go"}}}))
                            debug.traceback)]
            (set _G.print old-print)
            (set os.exit old-exit)
            (tset package.loaded "fen.extensions.print" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            (when (not ok?) (error err)))
          (assert.are.equal 1 (length exit-codes))
          (assert.are.equal 1 (. exit-codes 1))
          (assert.are.same [] lines))))

    (it "exits non-zero when the agent step raises"
      (fn []
        (let [old-agent (. package.loaded "fen.core.agent")
              old-lifecycle (. package.loaded "fen.turn_lifecycle")
              old-print _G.print
              lines []]
          (tset package.loaded "fen.extensions.print" nil)
          (tset package.loaded "fen.core.agent"
                {:step (fn [_ _] (error "boom"))})
          (tset package.loaded "fen.turn_lifecycle"
                {:emit-complete! (fn [_ _ _] nil)})
          (set _G.print (fn [line] (table.insert lines line)))
          (let [(ok? _err) (xpcall
                             #(let [print-presenter (require :fen.extensions.print)]
                                (print-presenter.run
                                  {:state {:agent {:name :agent :messages []}
                                           :opts {:print "go"}}}))
                             debug.traceback)]
            (set _G.print old-print)
            (tset package.loaded "fen.extensions.print" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            ;; The run must propagate the raised error (shared runner exits 1),
            ;; and must not have printed anything to stdout.
            (assert.is_false ok?))
          (assert.are.same [] lines))))))
