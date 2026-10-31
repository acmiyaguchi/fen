;; Known-bug probe for #619: the JSON presenter sums usage (and dumps
;; messages) over all of agent.messages, which after `--continue` includes the
;; replayed history, so headless usage is not this invocation's usage.
;; See spec/context/FINDINGS.md (#619).

(local json (require :fen.util.json))
(local {: known-bug} (require :fen.testing))

(describe "#619 json presenter usage after --continue"
          (fn []
            (it "includes the replayed exchange's usage"
                (fn []
                  (known-bug 619
                             (fn []
                               (let [old-agent (. package.loaded
                                                  "fen.core.agent")
                                     old-lifecycle (. package.loaded
                                                      "fen.turn_lifecycle")
                                     out-path (os.tmpname)
                                     ;; replayed by session_lifecycle.start! (--continue)
                                     messages [{:role :user :content "old"}
                                               {:role :assistant
                                                :content [{:type :text
                                                           :text "old answer"}]
                                                :usage {:input 50000
                                                        :output 900
                                                        :total-tokens 50900}
                                                :stop-reason :stop}]]
                                 (tset package.loaded "fen.extensions.json" nil)
                                 (tset package.loaded "fen.core.agent"
                                       {:step (fn [agent prompt]
                                                (table.insert agent.messages
                                                              {:role :user
                                                               :content prompt})
                                                (table.insert agent.messages
                                                              {:role :assistant
                                                               :content [{:type :text
                                                                          :text "new"}]
                                                               :usage {:input 7
                                                                       :output 3
                                                                       :total-tokens 10}
                                                               :stop-reason :stop})
                                                "new")})
                                 (tset package.loaded "fen.turn_lifecycle"
                                       {:emit-complete! (fn [] nil)})
                                 (let [(ok? err) (xpcall #(let [p (require :fen.extensions.json)]
                                                            (p.run {:state {:agent {: messages}
                                                                            :opts {:print "new turn"
                                                                                   :json-output-file out-path}}}))
                                                         debug.traceback)]
                                   (tset package.loaded "fen.extensions.json"
                                         nil)
                                   (tset package.loaded "fen.core.agent"
                                         old-agent)
                                   (tset package.loaded "fen.turn_lifecycle"
                                         old-lifecycle)
                                   (when (not ok?)
                                     (os.remove out-path)
                                     (error err)))
                                 (let [f (assert (io.open out-path :r))
                                       blob (json.decode (f:read :*a))]
                                   (f:close)
                                   (os.remove out-path)
                                   (and (= 50910 (. blob :usage :total-tokens))
                                        (= 50007 (. blob :usage :input))
                                        (= 4 (length blob.messages)))))))))))
