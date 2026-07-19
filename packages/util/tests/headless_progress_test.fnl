(local progress (require :fen.util.headless_progress))

(describe "headless progress"
  (fn []
    (it "formats turn, tool, and goal events as compact lines"
      (fn []
        (let [lines []
              times [1000 43000]
              next-time {:value 0}
              handler (progress.make-handler
                        {:clock (fn []
                                  (set next-time.value (+ next-time.value 1))
                                  (. times next-time.value))
                         :write-line (fn [line] (table.insert lines line))})]
          (handler {:type :llm-start})
          (handler {:type :tool-call
                    :name :read
                    :arguments {:path "src/fen/main.fnl"}})
          (handler {:type :llm-end :usage {:total-tokens 8200}})
          (handler {:type :info :source :goal :decision :continue
                    :iteration 3 :max-iterations 12 :status :running})
          (handler {:type :info :source :goal :decision :stop
                    :iteration 3 :max-iterations 12 :status :done})
          (assert.are.same
            ["[turn] started"
             "[tool] read src/fen/main.fnl"
             "[turn] 8.2k tokens, 42s elapsed"
             "[goal] iteration 3/12"
             "[goal] done 3/12"]
            lines))))

    (it "ignores transcript and streaming events with no active turn"
      (fn []
        (let [lines []
              handler (progress.make-handler
                        {:clock (fn [] 0)
                         :write-line (fn [line] (table.insert lines line))})]
          (handler {:type :assistant-text-delta :delta "secret result"})
          (handler {:type :message-appended :message {:content "secret result"}})
          (assert.are.same [] lines))))

    (it "emits a content-free rate-limited elapsed heartbeat from deltas"
      (fn []
        (let [lines []
              times [0 500 1200 1300 2500]
              idx {:value 0}
              handler (progress.make-handler
                        {:heartbeat-ms 1000
                         :clock (fn []
                                  (set idx.value (+ idx.value 1))
                                  (. times idx.value))
                         :write-line (fn [line] (table.insert lines line))})]
          (handler {:type :llm-start})               ; clock -> 0
          (handler {:type :assistant-text-delta :delta "secret"}) ; 500, too soon
          (handler {:type :assistant-text-delta :delta "more"})   ; 1200, emits
          (handler {:type :assistant-text-delta :delta "still"})  ; 1300, too soon
          (handler {:type :assistant-text-delta :delta "again"})  ; 2500, emits
          (assert.are.same
            ["[turn] started"
             "[turn] 1.2s elapsed"
             "[turn] 2.5s elapsed"]
            lines))))

    (it "does not heartbeat outside an active turn"
      (fn []
        (let [lines []
              handler (progress.make-handler
                        {:heartbeat-ms 1000
                         :clock (fn [] 999999)
                         :write-line (fn [line] (table.insert lines line))})]
          (handler {:type :assistant-text-delta :delta "secret"})
          (assert.are.same [] lines))))

    (it "renders a goal :start decision as iteration 1"
      (fn []
        (let [lines []
              handler (progress.make-handler
                        {:clock (fn [] 0)
                         :write-line (fn [line] (table.insert lines line))})]
          (handler {:type :info :source :goal :decision :start
                    :iteration 0 :max-iterations 8 :status :running})
          (assert.are.same ["[goal] iteration 1/8"] lines))))

    (it "keeps every emitted record to one bounded line"
      (fn []
        (let [lines []
              handler (progress.make-handler
                        {:clock (fn [] 0)
                         :write-line (fn [line] (table.insert lines line))})]
          (handler {:type :tool-call
                    :name :bash
                    :arguments {:cmd (.. "printf first\nsecond " (string.rep "x" 200))}})
          (assert.are.equal 1 (length lines))
          (assert.is_nil (string.find (. lines 1) "\n" 1 true))
          (assert.is_true (< (length (. lines 1)) 140)))))))
