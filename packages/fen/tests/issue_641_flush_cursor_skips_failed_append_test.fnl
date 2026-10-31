;; #641: the flush closure advances `last-saved` before `backend.append` and
;; ignores its result. The JSONL backend turns a write or open failure into a
;; warning and nil, so the message is never retried and is lost from the log.

(local types (require :fen.core.types))
(local session-lifecycle (require :fen.session_lifecycle))
(local h (require :fen.testing))
(local {: known-bug} h)

(describe "#641 flush cursor"
          (fn []
            (var tmp nil)
            (before_each (fn [] (set tmp (h.make-tmpdir))))
            (after_each (fn [] (when tmp (h.rmtree tmp))))
            (it "the JSONL append returns nil when its directory cannot be created"
                (fn []
                  (known-bug 641
                             (fn []
                               (let [S (require :fen.extensions.session_jsonl.session)
                                     blocker (.. tmp "/not-a-dir")
                                     f (assert (io.open blocker :w))]
                                 (f:close)
                                 (h.stub-log-fallback! (fn [_] nil))
                                 (let [s (S.open "/x")]
                                   (set s.path (.. blocker "/sub/s.jsonl"))
                                   (let [(ok? r) (pcall S.append s
                                                        (types.user-message "u"))]
                                     (h.restore-log-fallback!)
                                     (and ok? (= r nil)))))))))
            (it "drops a message whose append failed and never retries it"
                (fn []
                  (known-bug 641
                             (fn []
                               (let [disk []
                                     calls {:n 0}
                                     backend {:append (fn [_session msg]
                                                        (set calls.n
                                                             (+ calls.n 1))
                                                        ;; first write fails (ENOSPC, EIO, ...)
                                                        (when (> calls.n 1)
                                                          (table.insert disk
                                                                        msg)
                                                          msg))}
                                     agent {:messages []}
                                     flush (session-lifecycle.make-flush backend
                                                                         agent
                                                                         {:id :s}
                                                                         0)]
                                 (table.insert agent.messages
                                               (types.user-message "u1"))
                                 (table.insert agent.messages
                                               (types.assistant-message {:content [(types.text-block "a1")]}))
                                 (flush)
                                 (table.insert agent.messages
                                               (types.user-message "u2"))
                                 (flush)
                                 (and (= 3 (length agent.messages))
                                      (= 2 (length disk))
                                      (= :assistant (. disk 1 :role))))))))))
