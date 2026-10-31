;; #643: `session doctor` tracks pending tool-call ids as a set, so a result
;; anywhere after its call counts as paired. On the interleaved transcript of
;; #642 it reports no issues, and `--repair` copies the split pair unchanged.

(local types (require :fen.core.types))
(local am (require :fen.extensions.provider_anthropic.anthropic_messages))
(local h (require :fen.testing))
(local {: known-bug} h)

(fn wire-shape [wire]
  (let [out []]
    (each [_ m (ipairs wire)]
      (let [c (. m :content)
            kind (if (= (type c) :string) :text (. c (length c) :type))]
        (table.insert out (.. m.role ":" (tostring kind)))))
    (table.concat out " ")))

(fn text [s]
  (types.assistant-message {:content [(types.text-block s)]}))

(describe "#643 doctor pairing"
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
            (it "reports clean on a call split from its result"
                (fn []
                  (known-bug 643
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
                                       wire (wire-shape (am.convert-messages (S.load repaired.output-path)
                                                                             nil))]
                                   (and (= 0 report.issue-count)
                                        (= 0 repaired.issue-count)
                                        (= "user:text assistant:text user:text assistant:tool_use user:text assistant:text user:tool_result"
                                           wire))))))))))
