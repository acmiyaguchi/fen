;; #644: two processes can reclaim the same stale lock. Both read the dead
;; owner and pass the liveness probe and the re-read; the second then removes
;; the first's fresh owner file, rmdirs the now-empty lock dir, and its mkdir
;; succeeds too. Simulated in one process: as Q removes the owner file, P runs
;; a complete acquire-lock.

(local h (require :fen.testing))
(local {: known-bug} h)

(describe "#644 stale-lock reclaim"
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
            (it "grants the lock to both reclaimers"
                (fn []
                  (known-bug 644
                             (fn []
                               (let [s (S.create "/stale-race")
                                     lock-path (.. s.path ".lock")
                                     owner-path (.. lock-path "/owner")
                                     original-remove os.remove]
                                 (S.close s)
                                 (assert (os.execute (.. "mkdir "
                                                         (h.shellquote lock-path))))
                                 (let [owner (assert (io.open owner-path :w))]
                                   (owner:write "99999999")
                                   (owner:close))
                                 (var p-release nil)
                                 (var raced? false)
                                 (set os.remove
                                      (fn [p]
                                        (when (and (not raced?)
                                                   (= p owner-path))
                                          (set raced? true)
                                          ;; P: a full acquire-lock before Q's remove lands
                                          (set p-release (S.acquire-lock s)))
                                        (original-remove p)))
                                 (let [(ok? q-release) (pcall S.acquire-lock s)]
                                   (set os.remove original-remove)
                                   (assert ok? (tostring q-release))
                                   (when q-release (q-release))
                                   (and raced? (not= nil p-release)
                                        (not= nil q-release))))))))))
