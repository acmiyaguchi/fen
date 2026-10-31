;; A torn last line is terminated before the next append (#640). A process
;; killed partway through writing a line leaves a partial last line; the next
;; writer must start its entry on a fresh line, so the partial line costs only
;; the entry that was being written when the process died.

(local types (require :fen.core.types))
(local h (require :fen.testing))

(fn tear! [p]
  ;; killed mid-write: partial line, no newline
  (let [f (assert (io.open p :a))]
    (f:write "{\"type\":\"message\",\"id\":\"x\",\"mess")
    (f:close)))

(fn roles [msgs]
  (table.concat (icollect [_ m (ipairs msgs)] m.role) ","))

(describe "torn tail (#640)"
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
                           (h.stub-log-fallback! (fn [_] nil))
                           (set S
                                (h.reload-module :fen.extensions.session_jsonl.session))))
            (after_each (fn []
                          (h.restore-log-fallback!)
                          (h.restore-getenv!)
                          (when tmp (h.rmtree tmp))))
            (it "keeps the first entry appended after a torn line (open-existing)"
                (fn []
                  (let [s (S.open "/torn")]
                    (S.append s (types.user-message "one"))
                    (S.append s
                              (types.assistant-message {:content [(types.text-block "two")]}))
                    (S.close s)
                    (tear! s.path)
                    (assert.are.equal 2 (length (S.load s.path)))
                    (let [w (assert (S.open-existing s.path))
                          three (types.user-message "three")
                          entry (S.append w three)]
                      (S.append w
                                (types.assistant-message {:content [(types.text-block "four")]}))
                      (S.close w)
                      (assert.is_table entry)
                      (assert.are.equal entry.id three.__session-entry-id)
                      (let [after (S.load s.path)]
                        (assert.are.equal 4 (length after))
                        (assert.are.equal "user,assistant,user,assistant"
                                          (roles after))
                        (assert.are.equal "three" (. after 3 :content)))
                      ;; the partial line itself stays malformed (strict reads refuse it)
                      (assert.is_false (pcall S.load-strict s.path))))))
            (it "terminates a torn line when a closed handle reopens on its next append"
                (fn []
                  (let [s (S.open "/torn-reopen")]
                    (S.append s (types.user-message "one"))
                    (S.close s)
                    (tear! s.path)
                    (assert.is_table (S.append s
                                               (types.assistant-message {:content [(types.text-block "two")]})))
                    (S.close s)
                    (assert.are.equal "user,assistant" (roles (S.load s.path))))))
            (it "leaves a whole last line alone"
                (fn []
                  (let [s (S.open "/whole")]
                    (S.append s (types.user-message "one"))
                    (S.close s)
                    (let [size (with-open [f (assert (io.open s.path :rb))]
                                 (f:seek :end))
                          w (assert (S.open-existing s.path))]
                      (S.close w)
                      (assert.are.equal size
                                        (with-open [f (assert (io.open s.path
                                                                       :rb))]
                                          (f:seek :end)))))))))
