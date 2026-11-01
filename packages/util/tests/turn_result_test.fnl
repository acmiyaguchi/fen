;; Tests for fen.util.turn_result helpers.

(local turn-result (require :fen.util.turn_result))

(describe "fen.util.turn_result"
          (fn []
            (describe "last-assistant"
                      (fn []
                        (it "returns the last assistant message in order"
                            (fn []
                              (let [m1 {:role :user :content "hi"}
                                    m2 {:role :assistant
                                        :stop-reason :tool-use}
                                    m3 {:role :tool-result :content "ok"}
                                    m4 {:role :assistant :stop-reason :stop}]
                                (assert.are.equal m4
                                                  (turn-result.last-assistant [m1
                                                                               m2
                                                                               m3
                                                                               m4]))
                                (assert.are.equal m2
                                                  (turn-result.last-assistant [m1
                                                                               m2
                                                                               m3]))
                                (assert.is_nil (turn-result.last-assistant [m1
                                                                            m3]))
                                (assert.is_nil (turn-result.last-assistant []))
                                (assert.is_nil (turn-result.last-assistant nil)))))))
            (describe "failed?"
                      (fn []
                        (it "uses authoritative outcome when present"
                            (fn []
                              (let [msgs [{:role :assistant :stop-reason :stop}]]
                                (assert.is_false (turn-result.failed? true msgs
                                                                      {:status :ok}))
                                (assert.is_false (turn-result.failed? true
                                                                      [{:role :assistant
                                                                        :stop-reason :tool-use}]
                                                                      {:status :ok}))
                                (assert.is_true (turn-result.failed? true msgs
                                                                     {:status :error}))
                                (assert.is_true (turn-result.failed? true msgs
                                                                     {:status :cancelled}))
                                (assert.is_true (turn-result.failed? false msgs
                                                                     {:status :ok})))))
                        (it "falls back to inspecting messages when outcome is nil"
                            (fn []
                              (assert.is_true (turn-result.failed? false
                                                                   [{:role :assistant
                                                                     :stop-reason :stop}]))
                              (assert.is_true (turn-result.failed? true
                                                                   [{:role :user
                                                                     :content "go"}]))
                              (assert.is_true (turn-result.failed? true []))
                              (assert.is_true (turn-result.failed? true nil))
                              (assert.is_true (turn-result.failed? true
                                                                   [{:role :assistant
                                                                     :stop-reason :error}]))
                              (assert.is_true (turn-result.failed? true
                                                                   [{:role :assistant
                                                                     :stop-reason :tool-use}]))
                              (assert.is_true (turn-result.failed? true
                                                                   [{:role :assistant
                                                                     :stop-reason :aborted}]))
                              (assert.is_false (turn-result.failed? true
                                                                    [{:role :assistant
                                                                      :stop-reason :stop}]))))))
            (describe "sum-usage"
                      (fn []
                        (it "sums usage fields across assistant messages"
                            (fn []
                              (let [msgs [{:role :assistant
                                           :usage {:input 10
                                                   :output 5
                                                   :total 15}}
                                          {:role :user :content "next"}
                                          {:role :assistant
                                           :usage {:input 20
                                                   :output 10
                                                   :total 30}}]]
                                (assert.are.same {:input 30
                                                  :output 15
                                                  :total 45}
                                                 (turn-result.sum-usage msgs)))))
                        (it "returns nil when no assistant message has usage"
                            (fn []
                              (assert.is_nil (turn-result.sum-usage [{:role :user
                                                                      :content "hi"}]))
                              (assert.is_nil (turn-result.sum-usage []))
                              (assert.is_nil (turn-result.sum-usage nil))))))))
