;; #642: an interactive `--continue` takes the session's writer lock before it
;; reads the transcript, so a session another process (here: a held handle)
;; is writing is refused with exit 2 instead of being interleaved.

(local types (require :fen.core.types))
(local test-api (require :fen.core.extensions.test_api))
(local session-lifecycle (require :fen.session_lifecycle))
(local h (require :fen.testing))

(describe "--continue on a locked session (#642)"
          (fn []
            (var tmp nil)
            (var S nil)
            (var old-cwd nil)
            (before_each (fn []
                           (test-api.reset!)
                           (set tmp (h.make-tmpdir))
                           (h.stub-getenv! (fn [name orig]
                                             (if (= name :XDG_STATE_HOME) tmp
                                                 (orig name))))
                           (tset (require :fen.extensions.session_jsonl.state)
                                 :record-cache {})
                           (set S
                                (h.reload-module :fen.extensions.session_jsonl.session))
                           (set old-cwd session-lifecycle.cwd)
                           (set session-lifecycle.cwd (fn [] "/shared"))))
            (after_each (fn []
                          (set session-lifecycle.cwd old-cwd)
                          (test-api.reset!)
                          (h.restore-getenv!)
                          (when tmp (h.rmtree tmp))))
            (it "refuses while another handle holds the writer lock"
                (fn []
                  (let [s (S.create "/shared")]
                    (S.append s (types.user-message "one"))
                    (S.append s
                              (types.assistant-message {:content [(types.text-block "two")]}))
                    (S.close s)
                    (let [holder (assert (S.open-existing s.path))
                          backend {:name :jsonl
                                   :latest (fn [cwd] (S.latest-for-cwd cwd))
                                   :load (fn [p] (S.load p))
                                   :open (fn [cwd] (S.open cwd))
                                   :open-existing (fn [p] (S.open-existing p))}
                          old-exit os.exit
                          agent {:messages []}]
                      (var code nil)
                      (set os.exit (fn [c] (set code c) (error :exit-called)))
                      (let [ok? (pcall session-lifecycle.start!
                                       {:continue? true} agent backend)]
                        (set os.exit old-exit)
                        (S.close holder)
                        (assert.is_false ok?)
                        (assert.are.equal 2 code)
                        (assert.are.equal 0 (length agent.messages))
                        ;; once the holder closes, --continue succeeds
                        (let [(again replayed) (session-lifecycle.start! {:continue? true}
                                                                         {:messages []}
                                                                         backend)]
                          (assert.is_not_nil again)
                          (assert.are.equal 2 replayed)
                          (S.close again)))))))))
