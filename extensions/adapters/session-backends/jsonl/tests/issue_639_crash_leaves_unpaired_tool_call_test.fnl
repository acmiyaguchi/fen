;; #639: a crash while a tool runs leaves a tool call with no result in the
;; log; `load` replays it unchanged and the Anthropic converter does not repair
;; it, so the next request has a tool_use followed by a plain user message.

(local types (require :fen.core.types))
(local am (require :fen.extensions.provider_anthropic.anthropic_messages))
(local h (require :fen.testing))
(local {: known-bug} h)

(fn wire-shape [wire]
  "role:first-block-type for each wire message, e.g. assistant:tool_use."
  (let [out []]
    (each [_ m (ipairs wire)]
      (let [c (. m :content)
            kind (if (= (type c) :string) :text (. c (length c) :type))]
        (table.insert out (.. m.role ":" (tostring kind)))))
    (table.concat out " ")))

(describe "#639 crash mid-tool replay"
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
            (it "replays an unanswered tool call into an invalid Anthropic request"
                (fn []
                  (known-bug 639
                             (fn []
                               (let [s (S.open "/crash")]
                                 (S.append s (types.user-message "run it"))
                                 (S.append s
                                           (types.assistant-message {:api :anthropic-messages
                                                                     :provider :anthropic
                                                                     :model "m"
                                                                     :content [(types.tool-call-block "call-1"
                                                                                                      :bash
                                                                                                      {:command "sleep 100"})]
                                                                     :stop-reason :tool-use}))
                                 ;; process killed while the tool runs: no result
                                 (S.close s)
                                 (let [replayed (S.load s.path)]
                                   (table.insert replayed
                                                 (types.user-message "next"))
                                   (= "user:text assistant:tool_use user:text"
                                      (wire-shape (am.convert-messages replayed
                                                                       nil)))))))))))
