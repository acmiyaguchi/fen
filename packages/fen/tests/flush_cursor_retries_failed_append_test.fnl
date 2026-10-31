;; #641: the flush closure advances `last-saved` only after `backend.append`
;; confirms the write (returns the entry), stops at the first failure, and
;; retries that message, in order, on the next flush. The JSONL backend turns a
;; write or open failure into a warning and nil, which is the failure signal.

(local types (require :fen.core.types))
(local session-lifecycle (require :fen.session_lifecycle))
(local h (require :fen.testing))

(describe "#641 flush cursor"
          (fn []
            (var tmp nil)
            (before_each (fn [] (set tmp (h.make-tmpdir))))
            (after_each (fn [] (when tmp (h.rmtree tmp))))
            (it "the JSONL append returns nil when its directory cannot be created"
                (fn []
                  (do
                    (do
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
                            (assert.is_true ok?)
                            (assert.is_nil r))))))))
            (it "retries a message whose append failed, in order"
                (fn []
                  (do
                    (do
                      (let [disk []
                            calls {:n 0}
                            backend {:append (fn [_session msg]
                                               (set calls.n (+ calls.n 1))
                                               ;; first write fails (ENOSPC, EIO, ...)
                                               (when (> calls.n 1)
                                                 (table.insert disk msg)
                                                 msg))}
                            agent {:messages []}
                            flush (session-lifecycle.make-flush backend agent
                                                                {:id :s} 0)]
                        (table.insert agent.messages (types.user-message "u1"))
                        (table.insert agent.messages
                                      (types.assistant-message {:content [(types.text-block "a1")]}))
                        (flush)
                        (table.insert agent.messages (types.user-message "u2"))
                        (flush)
                        (assert.is_true (and (= 3 (length agent.messages))
                                             (= 3 (length disk))
                                             (= :user (. disk 1 :role))
                                             (= :assistant (. disk 2 :role))
                                             (= :user (. disk 3 :role)))))))))))
