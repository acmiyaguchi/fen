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

    (it "ignores transcript and streaming events"
      (fn []
        (let [lines []
              handler (progress.make-handler
                        {:clock (fn [] 0)
                         :write-line (fn [line] (table.insert lines line))})]
          (handler {:type :assistant-text-delta :delta "secret result"})
          (handler {:type :message-appended :message {:content "secret result"}})
          (assert.are.same [] lines))))

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
