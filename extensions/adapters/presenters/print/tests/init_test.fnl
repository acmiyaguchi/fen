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
                                 {:state {:agent {:name :agent}
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
          (assert.are.equal "ok" (. emitted 1 :result)))))))
