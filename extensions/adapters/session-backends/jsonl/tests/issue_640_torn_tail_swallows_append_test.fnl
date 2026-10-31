;; #640: a process killed partway through writing a line leaves a partial last
;; line; the next `append-entry` lands on the end of it, reports success, and
;; the entry is unreadable (and `load-strict` rejects the whole file).

(local types (require :fen.core.types))
(local h (require :fen.testing))
(local {: known-bug} h)

(describe "#640 torn tail"
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
            (it "loses the first entry appended after a torn line"
                (fn []
                  (known-bug 640
                             (fn []
                               (let [s (S.open "/torn")]
                                 (S.append s (types.user-message "one"))
                                 (S.append s
                                           (types.assistant-message {:content [(types.text-block "two")]}))
                                 (S.close s)
                                 ;; killed mid-write: partial line, no newline
                                 (let [f (assert (io.open s.path :a))]
                                   (f:write "{\"type\":\"message\",\"id\":\"x\",\"mess")
                                   (f:close))
                                 (let [before (length (S.load s.path))
                                       w (assert (S.open-existing s.path))
                                       three (types.user-message "three")
                                       entry (S.append w three)]
                                   (S.append w
                                             (types.assistant-message {:content [(types.text-block "four")]}))
                                   (S.close w)
                                   (let [after (S.load s.path)
                                         roles (icollect [_ m (ipairs after)]
                                                 m.role)
                                         (strict-ok?) (pcall S.load-strict
                                                             s.path)]
                                     (and (= before 2) (not= entry nil)
                                          (= (type three.__session-entry-id)
                                             :string)
                                          (= 3 (length after))
                                          (= "user,assistant,assistant"
                                             (table.concat roles ","))
                                          (not strict-ok?)))))))))))
