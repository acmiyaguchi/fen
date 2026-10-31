;; Replay closes interrupted tool calls (#639, #643). A crash while a tool runs
;; leaves the log ending at the assistant's tool call; `load` answers it with a
;; synthetic interrupted result, so the next request is valid for every
;; provider (the converters no longer repair on their own), and the doctor
;; reports and repairs exactly what replay changes.

(local types (require :fen.core.types))
(local am (require :fen.extensions.provider_anthropic.anthropic_messages))
(local oc (require :fen.extensions.provider_openai.openai_completions))
(local h (require :fen.testing))

(fn wire-shape [wire]
  "role:last-block-type for each wire message, e.g. assistant:tool_use."
  (let [out []]
    (each [_ m (ipairs wire)]
      (let [c (. m :content)
            kind (if (= (type c) :string) :text (. c (length c) :type))]
        (table.insert out (.. m.role ":" (tostring kind)))))
    (table.concat out " ")))

(fn call [id]
  (types.assistant-message {:api :anthropic-messages
                            :provider :anthropic
                            :model "m"
                            :content [(types.tool-call-block id :bash
                                                             {:command "sleep 100"})]
                            :stop-reason :tool-use}))

(fn result [id]
  (types.tool-result-message {:tool-call-id id
                              :tool-name :bash
                              :content [(types.text-block "ok")]}))

(fn text [s]
  (types.assistant-message {:content [(types.text-block s)]}))

(describe "replay closes interrupted tool calls (#639)"
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
            (it "answers a call the crash left open before the next prompt"
                (fn []
                  (let [s (S.open "/crash")]
                    (S.append s (types.user-message "run it"))
                    (S.append s (call "call-1"))
                    ;; process killed while the tool runs: no result
                    (S.close s)
                    (let [replayed (S.load s.path)]
                      (assert.are.equal 3 (length replayed))
                      (let [synthetic (. replayed 3)]
                        (assert.are.equal :tool-result synthetic.role)
                        (assert.are.equal "call-1" synthetic.tool-call-id)
                        (assert.is_true synthetic.is-error?)
                        (assert.is_true synthetic.details.interrupted?)
                        ;; in-memory only: never an entry on disk
                        (assert.is_nil synthetic.__session-entry-id))
                      (table.insert replayed (types.user-message "next"))
                      (assert.are.equal "user:text assistant:tool_use user:tool_result user:text"
                                        (wire-shape (am.convert-messages replayed
                                                                         nil)))
                      (assert.are.equal "user assistant tool user"
                                        (table.concat (icollect [_ m (ipairs (oc.convert-messages replayed
                                                                                                  nil))]
                                                        m.role)
                                                      " "))))))
            (it "repairs a call split from its result by another writer, and drops the late result"
                (fn []
                  (let [s (S.open "/split")]
                    (each [_ m (ipairs [(types.user-message "one")
                                        (text "two")
                                        (types.user-message "A2")
                                        (call "call-A")
                                        (types.user-message "B prompt")
                                        (text "B reply")
                                        (result "call-A")])]
                      (S.append s m))
                    (S.close s)
                    (let [raw []]
                      (each [line (io.lines s.path)]
                        (table.insert raw line))
                      (let [(_ repairs) (S.replay-messages (icollect [_ m (ipairs (S.load s.path))]
                                                             m))]
                        ;; load already repaired it: replaying again changes nothing
                        (assert.are.equal 0 repairs))
                      (assert.are.equal 8 (length raw)))
                    (assert.are.equal "user:text assistant:text user:text assistant:tool_use user:tool_result user:text assistant:text"
                                      (wire-shape (am.convert-messages (S.load s.path)
                                                                       nil))))))
            (it "keeps results answered in any order and is idempotent"
                (fn []
                  (let [asst (types.assistant-message {:content [(types.tool-call-block "a"
                                                                                        :ls
                                                                                        {})
                                                                 (types.tool-call-block "b"
                                                                                        :ls
                                                                                        {})]
                                                       :stop-reason :tool-use})
                        msgs [(types.user-message "go")
                              asst
                              (result "b")
                              (result "a")
                              (result "a")]
                        (once n1) (S.replay-messages msgs)
                        (twice n2) (S.replay-messages once)]
                    ;; the duplicate result answers nothing and is dropped
                    (assert.are.equal 1 n1)
                    (assert.are.equal 4 (length once))
                    (assert.are.equal 0 n2)
                    (assert.are.same once twice))))
            (it "does not treat error turns as carrying open calls"
                (fn []
                  (let [err (types.assistant-message {:content [(types.tool-call-block "e"
                                                                                       :ls
                                                                                       {})]
                                                      :stop-reason :error})
                        (out n) (S.replay-messages [(types.user-message "go")
                                                    err
                                                    (types.user-message "again")])]
                    (assert.are.equal 0 n)
                    (assert.are.equal 3 (length out)))))
            (it "doctor reports exactly what replay changes and repairs to the replayed log"
                (fn []
                  (let [s (S.open "/doctor-replay")]
                    (each [_ m (ipairs [(types.user-message "one")
                                        (call "call-1")
                                        (types.user-message "two")
                                        (result "nobody")
                                        (text "three")
                                        (call "call-2")])]
                      (S.append s m))
                    (S.close s)
                    (let [report (S.doctor s.path)
                          raw (let [out []]
                                (each [line (io.lines s.path)]
                                  (let [json (require :fen.util.json)
                                        entry (json.decode line)]
                                    (when (= entry.type :message)
                                      (table.insert out entry.message))))
                                out)
                          (_ replay-repairs) (S.replay-messages raw)
                          codes (icollect [_ issue (ipairs report.issues)]
                                  issue.code)]
                      (assert.are.equal 3 replay-repairs)
                      (assert.are.equal replay-repairs report.issue-count)
                      (table.sort codes)
                      (assert.are.same [:missing_tool_result
                                        :missing_tool_result
                                        :orphan_tool_result]
                                       codes)
                      (let [repaired (S.doctor s.path true)
                            again (S.doctor repaired.output-path)]
                        (assert.are.equal 0 again.issue-count)
                        (assert.are.same (icollect [_ m (ipairs (S.load s.path))]
                                           [m.role (or m.tool-call-id "")])
                                         (icollect [_ m (ipairs (S.load repaired.output-path))]
                                           [m.role (or m.tool-call-id "")])))))))))
