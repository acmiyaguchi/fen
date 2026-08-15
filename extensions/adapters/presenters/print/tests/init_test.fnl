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
          (let [(ok? result) (xpcall
                            #(let [print-presenter (require :fen.extensions.print)]
                               (print-presenter.run
                                 {:state {:agent {:name :agent :messages []}
                                          :opts {:print "/literal prompt"}}}))
                            debug.traceback)]
            (set _G.print old-print)
            (tset package.loaded "fen.extensions.print" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            (when (not ok?) (error result))
            (assert.are.equal 0 result))
          (assert.are.same ["ok"] lines)
          (assert.are.equal 1 (length emitted))
          (assert.is_true (. emitted 1 :ok?))
          (assert.are.equal "ok" (. emitted 1 :result)))))

    (it "returns a non-zero exit code and prints nothing to stdout on a provider-error turn"
      (fn []
        (let [old-agent (. package.loaded "fen.core.agent")
              old-lifecycle (. package.loaded "fen.turn_lifecycle")
              old-print _G.print
              lines []
              emitted []
              ;; agent.step records provider errors as stop-reason :error instead of raising; must count as a failed turn.
              messages [{:role :user :content "go"}
                        {:role :assistant
                         :content [{:type :text :text "[error] HTTP 400"}]
                         :stop-reason :error}]]
          (tset package.loaded "fen.extensions.print" nil)
          (tset package.loaded "fen.core.agent"
                {:step (fn [_ _] "[error] HTTP 400")})
          (tset package.loaded "fen.turn_lifecycle"
                {:emit-complete! (fn [_state ok? result]
                                   (table.insert emitted {:ok? ok? :result result}))})
          (set _G.print (fn [line] (table.insert lines line)))
          (let [(ok? result) (xpcall
                            #(let [print-presenter (require :fen.extensions.print)]
                               (print-presenter.run
                                 {:state {:agent {:name :agent
                                                  :messages messages}
                                          :opts {:print "go"}}}))
                            debug.traceback)]
            (set _G.print old-print)
            (tset package.loaded "fen.extensions.print" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            (when (not ok?) (error result))
            (assert.are.equal 1 result))
          (assert.are.same [] lines)
          (assert.are.equal 1 (length emitted)))))

    (it "returns a non-zero exit code when the turn ends without a final assistant reply"
      (fn []
        (let [old-agent (. package.loaded "fen.core.agent")
              old-lifecycle (. package.loaded "fen.turn_lifecycle")
              old-print _G.print
              lines []
              ;; A final :tool-use means safety-cap exhaustion.
              messages [{:role :user :content "go"}
                        {:role :assistant
                         :content [{:type :tool-call :name "noop"}]
                         :stop-reason :tool-use}]]
          (tset package.loaded "fen.extensions.print" nil)
          (tset package.loaded "fen.core.agent"
                {:step (fn [_ _] "[error] tool-call loop exceeded safety cap")})
          (tset package.loaded "fen.turn_lifecycle"
                {:emit-complete! (fn [_ _ _] nil)})
          (set _G.print (fn [line] (table.insert lines line)))
          (let [(ok? result) (xpcall
                            #(let [print-presenter (require :fen.extensions.print)]
                               (print-presenter.run
                                 {:state {:agent {:name :agent
                                                  :messages messages}
                                          :opts {:print "go"}}}))
                            debug.traceback)]
            (set _G.print old-print)
            (tset package.loaded "fen.extensions.print" nil)
            (tset package.loaded "fen.core.agent" old-agent)
            (tset package.loaded "fen.turn_lifecycle" old-lifecycle)
            (when (not ok?) (error result))
            (assert.are.equal 1 result))
          (assert.are.same [] lines))))

    (it "propagates a raised agent step so the CLI runner exits non-zero"
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
            (assert.is_false ok?))
          (assert.are.same [] lines))))))
