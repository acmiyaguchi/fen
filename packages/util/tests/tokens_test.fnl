(local tokens (require :fen.util.tokens))

(describe "fen.util.tokens"
  (fn []
    (it "estimates message and context tokens"
      (fn []
        (let [agent {:system-prompt "system"
                     :messages [{:role :user :content "hello"}
                                {:role :assistant
                                 :content [{:type :text :text "answer"}
                                           {:type :tool-call
                                            :name :read
                                            :arguments {:path "README.md"}}]}
                                {:role :tool-result
                                 :tool-name :read
                                 :content [{:type :text :text "contents"}]}]}]
          (assert.is_true (> (tokens.estimated-context-tokens agent) 0))
          (assert.are.equal (tokens.estimated-context-tokens agent)
                            (. agent.context-token-ledger :total)))))

    (it "updates a valid agent ledger incrementally on append"
      (fn []
        (let [agent {:system-prompt "sys" :messages []}
              first {:role :user :content "12345678"}
              second {:role :assistant :content [{:type :text :text "abcd"}]}]
          (assert.are.equal 1 (tokens.estimated-context-tokens agent))
          (table.insert agent.messages first)
          (tokens.note-message-appended! agent first 1)
          (let [after-first (tokens.estimated-context-tokens agent)
                ledger agent.context-token-ledger]
            (assert.are.equal 1 ledger.message-count)
            (assert.are.equal after-first ledger.total)
            (table.insert agent.messages second)
            (tokens.note-message-appended! agent second 2)
            (assert.are.equal 2 agent.context-token-ledger.message-count)
            (assert.is_true (> (tokens.estimated-context-tokens agent)
                               after-first))))))

    (it "rebuilds once after direct message-table replacement"
      (fn []
        (let [agent {:system-prompt "sys" :messages []}]
          (tokens.estimated-context-tokens agent)
          (let [old-ledger agent.context-token-ledger]
            (set agent.messages [{:role :user :content "replacement"}])
            (let [n (tokens.estimated-context-tokens agent)]
              (assert.is_true (> n 0))
              (assert.are_not.equal old-ledger agent.context-token-ledger)
              (assert.are.equal agent.messages agent.context-token-ledger.messages-ref)
              (assert.are.equal 1 agent.context-token-ledger.message-count))))))

    (it "invalidates instead of walking history when append sees a stale ledger"
      (fn []
        (let [agent {:system-prompt "sys"
                     :messages [{:role :user :content "manual"}]}
              msg {:role :assistant :content "later"}]
          (tokens.estimated-context-tokens agent)
          (set agent.messages [{:role :user :content "other"}])
          (table.insert agent.messages msg)
          (assert.is_nil (tokens.note-message-appended! agent msg 2))
          (assert.is_nil agent.context-token-ledger)
          (assert.is_true (> (tokens.estimated-context-tokens agent) 0)))))

    (it "formats token counts and usage summaries"
      (fn []
        (assert.are.equal "999" (tokens.fmt-tokens 999))
        (assert.are.equal "1.5k" (tokens.fmt-tokens 1500))
        (assert.are.equal "12k" (tokens.fmt-tokens 12345))
        (assert.are.equal "1.2M" (tokens.fmt-tokens 1200000))
        (let [usage (tokens.usage-totals
                      [{:role :assistant :usage {:input 10 :output 5}}
                       {:role :assistant :usage {:input 2 :output 3
                                                 :cache-read 4
                                                 :cache-write 1
                                                 :total-tokens 99}}])]
          (assert.are.equal 12 usage.input)
          (assert.are.equal 8 usage.output)
          (assert.are.equal 4 usage.cache-read)
          (assert.are.equal 1 usage.cache-write)
          (assert.are.equal 114 usage.total-tokens)
          (assert.are.equal "↑12 ↓8 R4 W1  ctx:~42"
                            (tokens.format-token-summary usage 42)))))))
