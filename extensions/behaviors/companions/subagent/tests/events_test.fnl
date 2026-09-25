(local json (require :fen.util.json))
(local types (require :fen.core.types))
(local sub-events (require :fen.extensions.subagent.events))

(fn call-msg [ids ?stop-reason]
  (let [content []]
    (each [_ id (ipairs ids)]
      (table.insert content (types.tool-call-block id "read" {:path id})))
    (types.assistant-message {:content content
                              :stop-reason (or ?stop-reason :tool-use)})))

(fn result-msg [id text]
  (types.tool-result-message {:tool-call-id id :tool-name "read"
                              :content [(types.text-block text)]}))

(fn roles [messages]
  (let [out []]
    (each [_ m (ipairs messages)]
      (table.insert out (if (= m.role :tool-result)
                            (.. "result:" m.tool-call-id)
                            m.role)))
    (table.concat out ",")))

(describe "subagent canonical transcript"
  (fn []
    (it "round-trips canonical messages through append and read"
      (fn []
        (let [p (os.tmpname)
              msgs [(types.user-message "task")
                    (call-msg ["a"])
                    (result-msg "a" "fact")]]
          (each [_ m (ipairs msgs)]
            (set m.__session-entry-id "dropped")
            (assert.is_true (sub-events.append-transcript-message! p m)))
          (let [(read stats) (sub-events.read-transcript p)]
            (os.remove p)
            (assert.are.equal :ok stats.status)
            (assert.are.equal 0 stats.malformed)
            (assert.are.equal 3 (length read))
            (assert.are.equal "fact" (. read 3 :content 1 :text))
            (assert.are.equal "a" (. read 2 :content 1 :id))
            (assert.is_nil (. read 1 :__session-entry-id))))))

    (it "counts a record cut short mid-write and gap markers as unrecovered"
      (fn []
        (let [p (os.tmpname)
              f (assert (io.open p :w))]
          (f:write (json.encode (types.user-message "task")) "\n")
          (f:write (json.encode {:transcript-gap "not encodable"}) "\n")
          (f:write "{\"role\":\"tool-result\",\"content\":[{\"ty")
          (f:close)
          (let [(read stats) (sub-events.read-transcript p)]
            (os.remove p)
            (assert.are.equal 1 (length read))
            (assert.are.equal 1 stats.malformed)
            (assert.are.equal 1 stats.gaps)))))

    (it "reports a missing transcript without failing"
      (fn []
        (let [(read stats) (sub-events.read-transcript "/nonexistent/fen-transcript")]
          (assert.are.equal 0 (length read))
          (assert.are.equal :missing stats.status))))

    (it "closes the transcript handle when the yield callback unwinds"
      (fn []
        (let [p (os.tmpname)
              marker {:type :cancel-marker}]
          (for [i 1 70]
            (sub-events.append-transcript-message! p (types.user-message (.. "m" i))))
          (let [(ok? err) (pcall sub-events.read-transcript p (fn [] (error marker)))]
            (os.remove p)
            (assert.is_false ok?)
            (assert.are.equal marker err)))))

    (it "adds interrupted results for in-flight tool calls in their group"
      (fn []
        (let [(out stats) (sub-events.repair-transcript
                            [(types.user-message "task")
                             (call-msg ["a" "b" "c"])
                             (result-msg "a" "done")
                             (types.user-message "steer")
                             (call-msg ["d"])])]
          (assert.are.equal
            "user,assistant,result:a,result:b,result:c,user,assistant,result:d"
            (roles out))
          (assert.are.equal 3 stats.interrupted-tool-calls)
          (assert.are.equal 0 stats.orphan-tool-results)
          (let [synthetic (. out 4)]
            (assert.is_true synthetic.is-error?)
            (assert.are.equal sub-events.INTERRUPTED-TOOL-TEXT
                              (. synthetic.content 1 :text))))))

    (it "drops orphan and duplicate results and ignores error-turn calls"
      (fn []
        (let [(out stats) (sub-events.repair-transcript
                            [(types.user-message "task")
                             (result-msg "zz" "orphan")
                             (call-msg ["a"])
                             (result-msg "a" "one")
                             (result-msg "a" "duplicate")
                             (call-msg ["e"] :error)])]
          (assert.are.equal "user,assistant,result:a,assistant" (roles out))
          (assert.are.equal 2 stats.orphan-tool-results)
          (assert.are.equal 0 stats.interrupted-tool-calls))))

    (it "leaves complete paired history untouched"
      (fn []
        (let [input [(types.user-message "task")
                     (call-msg ["a"])
                     (result-msg "a" "one")
                     (types.assistant-message {:content [(types.text-block "final")]})]
              (out stats) (sub-events.repair-transcript input)]
          (assert.are.equal (length input) (length out))
          (assert.are.equal 0 stats.interrupted-tool-calls)
          (assert.are.equal 0 stats.orphan-tool-results))))

    (it "rewrites a repaired transcript for the next attempt"
      (fn []
        (let [p (os.tmpname)
              f (assert (io.open p :w))]
          (f:write "partial garbage")
          (f:close)
          (assert.is_true (sub-events.write-transcript!
                            p [(types.user-message "task") (call-msg ["a"])
                               (result-msg "a" "one")]))
          (let [(read stats) (sub-events.read-transcript p)]
            (os.remove p)
            (assert.are.equal 3 (length read))
            (assert.are.equal 0 stats.malformed)))))))
