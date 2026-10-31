;; The session writer lock has one holder and nothing to reclaim (#644). It is
;; a kernel record lock on a `.writer.lock` file that is never removed, so a
;; crashed holder's lock dies with its process; there is no owner file, no
;; liveness probe, and no remove-then-recreate step for two reclaimers to race
;; through. (The cross-process case is in session_test.fnl.)

(local h (require :fen.testing))

(describe "writer lock (#644)"
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
            (it "grants a lock left behind by a dead holder to exactly one acquirer, removing nothing"
                (fn []
                  (let [s (S.create "/stale-race")
                        lock-path (.. s.path ".writer.lock")
                        original-remove os.remove
                        original-execute os.execute
                        removed []]
                    (S.close s)
                    ;; a lock file left by a crashed holder
                    (with-open [f (assert (io.open lock-path :w))]
                      (f:write "99999999"))
                    (var q-release nil)
                    (set os.remove
                         (fn [p]
                           (table.insert removed p)
                           (original-remove p)))
                    (set os.execute
                         (fn [cmd]
                           (table.insert removed cmd)
                           (original-execute cmd)))
                    (let [(ok? p-release) (pcall S.acquire-lock s)]
                      (set q-release (S.acquire-lock s))
                      (set os.remove original-remove)
                      (set os.execute original-execute)
                      (assert.is_true ok? (tostring p-release))
                      (assert.is_function p-release)
                      (assert.is_nil q-release)
                      (assert.are.same [] removed)
                      (p-release)
                      (let [again (S.acquire-lock s)]
                        (assert.is_function again)
                        (again))))))))
