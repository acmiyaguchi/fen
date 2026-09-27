;; Compaction questions (tool-result rating, auto-compaction moment) through a
;; mocked decide service (#512, #511).

(local types (require :fen.core.types))

(local original-service (. package.loaded :fen.extensions.decide.service))
(local original-compaction (. package.loaded :fen.extensions.decide.compaction))

(fn restore-modules! []
  (tset package.loaded :fen.extensions.decide.service original-service)
  (tset package.loaded :fen.extensions.decide.compaction original-compaction))

(fn mock-service [?opts]
  "Service stub: `ask` answers through opts.ask, `ask-async!` records requests
   so tests answer them by hand."
  (let [opts (or ?opts {})
        calls []
        asks []]
    (values {:enabled? (fn [] (not= opts.enabled? false))
             :max-request-bytes (or opts.max-request-bytes 60000)
             :ask (fn [st questions ask-opts]
                    (table.insert calls {:state st :questions questions :opts ask-opts})
                    (if opts.ask (opts.ask st questions ask-opts) nil))
             :ask-async! (fn [st questions on-done]
                           (table.insert asks {:state st :questions questions :on-done on-done}))}
            calls
            asks)))

(fn load-compaction [service]
  (tset package.loaded :fen.extensions.decide.service service)
  (tset package.loaded :fen.extensions.decide.compaction nil)
  (require :fen.extensions.decide.compaction))

(fn large-text []
  (string.rep "x" 90000))

(fn tool-messages []
  "Older span (first five): a large user turn, a `read` result, a `bash`
   result, and a tiny `ls` result; then the recent request and reply."
  (let [read-out (.. "READ-HEAD " (string.rep "r" 4000) " READ-TAIL")
        bash-out (.. "BASH-HEAD " (string.rep "b" 4000) " BASH-TAIL")]
    [(types.user-message (large-text))
     (types.assistant-message
       {:api :test :provider :test :model "m"
        :content [(types.tool-call-block "tc1" :read {:path "src/a.fnl"})
                  (types.tool-call-block "tc2" :bash {:command "make test"})
                  (types.tool-call-block "tc3" :ls {})]
        :stop-reason :tool-use})
     (types.tool-result-message
       {:tool-call-id "tc1" :tool-name :read
        :content [(types.text-block read-out)]})
     (types.tool-result-message
       {:tool-call-id "tc2" :tool-name :bash
        :content [(types.text-block bash-out)]})
     (types.tool-result-message
       {:tool-call-id "tc3" :tool-name :ls
        :content [(types.text-block "tiny")]})
     (types.user-message "recent user: fix the failing test")
     (types.assistant-message
       {:api :test :provider :test :model "m"
        :content [(types.text-block "recent assistant")]
        :stop-reason :stop})]))

(fn older-span [messages]
  [(. messages 1) (. messages 2) (. messages 3) (. messages 4) (. messages 5)])

(fn answers-by-tool [probabilities]
  "Answer each question with the probability configured for its tool."
  (fn [st questions _opts]
    (collect [id _ (pairs questions)]
      id {:type :noul :noul (. probabilities (. st.tool_results id :tool))})))

(fn span-text [span i]
  (?. span i :content 1 :text))

(fn has? [s needle]
  (not= nil (string.find (or s "") needle 1 true)))

(describe "fen.extensions.decide.compaction rate-tool-results"
  (fn []
    (after_each restore-modules!)

    (it "stubs results rated no longer needed and passes the rest through"
      (fn []
        (let [(service calls) (mock-service {:ask (answers-by-tool {:read 0.2 :bash 0.95})})
              compaction (load-compaction service)
              messages (tool-messages)
              span (older-span messages)
              yield! (fn [] nil)
              (out dropped) (compaction.rate-tool-results messages span yield!)]
          (assert.are.equal 1 (length calls))
          (let [call (. calls 1)
                tools (collect [id item (pairs call.state.tool_results)] item.tool id)]
            ;; The tiny ls result is below the rating floor.
            (assert.is_not_nil tools.read)
            (assert.is_not_nil tools.bash)
            (assert.is_nil tools.ls)
            (assert.are.equal :noul (. call.questions tools.bash :type))
            (assert.are.equal yield! call.opts.yield)
            (assert.is_true (has? call.state.request "fix the failing test"))
            (assert.is_true (has? (. call.state.tool_results tools.bash :output) "BASH-TAIL"))
            (assert.is_true (has? (. call.state.tool_results tools.bash :output) "bytes omitted")))
          (assert.are.equal 1 dropped)
          (assert.are.equal 5 (length out))
          (assert.is_true (has? (span-text out 3) "READ-HEAD"))
          (assert.are.equal "[tool result omitted before compaction: bash {\"command\":\"make test\"}, 4020 bytes]"
                            (span-text out 4))
          (assert.are.equal :tool-result (. out 4 :role))
          (assert.are.equal "tiny" (span-text out 5))
          ;; Stubs live only in the returned copy.
          (assert.is_true (has? (span-text span 4) "BASH-HEAD"))
          (assert.is_true (has? (span-text messages 4) "BASH-HEAD")))))

    (it "passes through results below the threshold, including uncertain ones"
      (fn []
        (let [(service calls) (mock-service {:ask (answers-by-tool {:read 0.79 :bash 0.5})})
              compaction (load-compaction service)
              messages (tool-messages)
              (out dropped) (compaction.rate-tool-results messages (older-span messages))]
          (assert.are.equal 1 (length calls))
          (assert.are.equal 0 dropped)
          (assert.is_true (has? (span-text out 3) "READ-HEAD"))
          (assert.is_true (has? (span-text out 4) "BASH-HEAD")))))

    (it "returns the span unchanged when decide returns nil"
      (fn []
        (let [(service calls) (mock-service)
              compaction (load-compaction service)
              messages (tool-messages)
              (out dropped) (compaction.rate-tool-results messages (older-span messages))]
          (assert.are.equal 1 (length calls))
          (assert.are.equal 0 dropped)
          (assert.is_true (has? (span-text out 3) "READ-HEAD"))
          (assert.is_true (has? (span-text out 4) "BASH-HEAD")))))

    (it "does not ask when decide is disabled"
      (fn []
        (let [(service calls) (mock-service {:enabled? false
                                             :ask (answers-by-tool {:read 1 :bash 1})})
              compaction (load-compaction service)
              messages (tool-messages)
              span (older-span messages)
              (out dropped) (compaction.rate-tool-results messages span)]
          (assert.are.equal 0 (length calls))
          (assert.are.equal span out)
          (assert.are.equal 0 dropped))))

    (it "splits ratings across requests that fit the size guard"
      (fn []
        (let [(service calls) (mock-service {:ask (answers-by-tool {:read 0.9 :bash 0.9})
                                             :max-request-bytes 6000})
              compaction (load-compaction service)
              messages (tool-messages)
              (out dropped) (compaction.rate-tool-results messages (older-span messages))]
          (assert.are.equal 2 (length calls))
          (assert.are.equal 2 dropped)
          (assert.is_false (has? (span-text out 3) "READ-HEAD"))
          (assert.is_false (has? (span-text out 4) "BASH-HEAD")))))

    (it "propagates errors raised by the caller's yield"
      (fn []
        (let [(service calls) (mock-service {:ask (fn [_st _qs opts] (opts.yield) nil)})
              compaction (load-compaction service)
              messages (tool-messages)
              cancel-marker {:type :test-cancel}
              (ok? err) (pcall compaction.rate-tool-results messages (older-span messages)
                               (fn [] (error cancel-marker)))]
          (assert.is_false ok?)
          (assert.are.equal cancel-marker err)
          (assert.are.equal 1 (length calls)))))))

(fn moment-messages []
  [(types.user-message (large-text))
   (types.assistant-message
     {:api :test :provider :test :model "m"
      :content [(types.text-block (large-text))]
      :stop-reason :stop})
   (types.user-message "recent user")
   (types.assistant-message
     {:api :test :provider :test :model "m"
      :content [(types.text-block "recent assistant")]
      :stop-reason :stop})])

(fn good-moment [p]
  {:good_moment {:type :noul :noul p}})

(describe "fen.extensions.decide.compaction ask-good-moment!"
  (fn []
    (after_each restore-modules!)

    (it "asks once over the message tails and calls on-good at 0.7 or more"
      (fn []
        (let [(service _calls asks) (mock-service)
              compaction (load-compaction service)
              good {:n 0}]
          (compaction.ask-good-moment! (moment-messages) (fn [] (set good.n (+ good.n 1))))
          (assert.are.equal 1 (length asks))
          (let [ask (. asks 1)
                recent ask.state.recent_messages]
            (assert.are.equal :noul (. ask.questions :good_moment :type))
            (assert.is_true (has? (. ask.questions :good_moment :instructions) "good moment to compact"))
            (assert.are.equal 4 (length recent))
            (assert.are.equal "recent assistant" (. recent 4 :text))
            (assert.is_true (<= (length (. recent 1 :text)) 404))
            (assert.are.equal 0 good.n)
            (ask.on-done (good-moment 0.9)))
          (assert.are.equal 1 good.n))))

    (it "keeps the last six messages and names tool results"
      (fn []
        (let [(service _calls asks) (mock-service)
              compaction (load-compaction service)
              messages (tool-messages)]
          (table.insert messages 1 (types.user-message "dropped from the window"))
          (compaction.ask-good-moment! messages (fn [] nil))
          (let [recent (. asks 1 :state :recent_messages)]
            (assert.are.equal 6 (length recent))
            (assert.are.equal :read (. recent 2 :tool))
            (assert.is_false (. recent 2 :is_error))
            (assert.are.equal "[tool-call read]\n[tool-call bash]\n[tool-call ls]"
                              (. recent 1 :text))))))

    (it "does not call on-good when work is mid-flight or decide fails"
      (fn []
        (each [_ answers (ipairs [(good-moment 0.3) (good-moment 0.69) nil {}])]
          (let [(service _calls asks) (mock-service)
                compaction (load-compaction service)
                good {:n 0}]
            (compaction.ask-good-moment! (moment-messages) (fn [] (set good.n (+ good.n 1))))
            ((. asks 1 :on-done) answers)
            (assert.are.equal 0 good.n)))))

    (it "asks nothing when decide is disabled"
      (fn []
        (let [(service _calls asks) (mock-service {:enabled? false})
              compaction (load-compaction service)
              good {:n 0}]
          (compaction.ask-good-moment! (moment-messages) (fn [] (set good.n (+ good.n 1))))
          (assert.are.equal 0 (length asks))
          (assert.are.equal 0 good.n))))))
