;; The doctor checks tool pairing by order, as providers do (#643). A result
;; that arrives after other messages does not pair with its call: the doctor
;; reports the call as missing its result and the late result as an orphan,
;; and `--repair` writes what replay would build (the interleaved transcript of
;; #642, written before writers held the lock).

(local types (require :fen.core.types))
(local am (require :fen.extensions.provider_anthropic.anthropic_messages))
(local h (require :fen.testing))

(fn wire-shape [wire]
  (let [out []]
    (each [_ m (ipairs wire)]
      (let [c (. m :content)
            kind (if (= (type c) :string) :text (. c (length c) :type))]
        (table.insert out (.. m.role ":" (tostring kind)))))
    (table.concat out " ")))

(fn text [s]
  (types.assistant-message {:content [(types.text-block s)]}))

(describe "doctor pairing (#643)"
          (fn []
            (var tmp nil)
            (var S nil)
            (before_each (fn []
                           (set tmp (h.make-tmpdir))
                           (h.stub-getenv! (fn [name orig]
                                             (if (= name :XDG_STATE_HOME) tmp
                                                 (orig name))))
                           (tset (require :fen.extensions.session_jsonl.state)
                                 :record-cache {})
                           (set S
                                (h.reload-module :fen.extensions.session_jsonl.session))))
            (after_each (fn []
                          (h.restore-getenv!)
                          (when tmp (h.rmtree tmp))))
            (it "reports and repairs a call split from its result"
                (fn []
                  (let [s (S.open "/doctor-order")]
                    (each [_ m (ipairs [(types.user-message "one")
                                        (text "two")
                                        (types.user-message "A2")
                                        (types.assistant-message {:content [(types.tool-call-block "call-A"
                                                                                                   :bash
                                                                                                   {})]
                                                                  :stop-reason :tool-use})
                                        (types.user-message "B prompt")
                                        (text "B reply")
                                        (types.tool-result-message {:tool-call-id "call-A"
                                                                    :tool-name :bash
                                                                    :content [(types.text-block "ok")]})])]
                      (S.append s m))
                    (S.close s)
                    (let [report (S.doctor s.path)
                          repaired (S.doctor s.path true)
                          codes (icollect [_ issue (ipairs report.issues)]
                                  (.. issue.code "@" issue.line))]
                      (assert.are.same ["missing_tool_result@5"
                                        "orphan_tool_result@8"]
                                       codes)
                      (assert.are.equal 2 repaired.issue-count)
                      (assert.are.equal 0
                                        (. (S.doctor repaired.output-path)
                                           :issue-count))
                      (assert.are.equal "user:text assistant:text user:text assistant:tool_use user:tool_result user:text assistant:text"
                                        (wire-shape (am.convert-messages (S.load repaired.output-path)
                                                                         nil)))))))))
