;; #642: only `session send` takes the session lock. `fen --continue`
;; (session_lifecycle.start!) opens the same transcript for append without it,
;; so while a sender holds the lock both processes write the file and a tool
;; call is split from its result.

(local types (require :fen.core.types))
(local am (require :fen.extensions.provider_anthropic.anthropic_messages))
(local test-api (require :fen.core.extensions.test_api))
(local session-lifecycle (require :fen.session_lifecycle))
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

(describe "#642 interactive writer and session lock"
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
            (it "lets --continue append while a sender holds the lock"
                (fn []
                  (known-bug 642
                             (fn []
                               (let [s (S.create "/shared")]
                                 (S.append s (types.user-message "one"))
                                 (S.append s (text "two"))
                                 (S.close s)
                                 (var lock-calls 0)
                                 (let [backend {:name :jsonl
                                                :latest (fn [cwd]
                                                          (S.latest-for-cwd cwd))
                                                :load (fn [p] (S.load p))
                                                :open (fn [cwd] (S.open cwd))
                                                :open-existing (fn [p]
                                                                 (S.open-existing p))
                                                :acquire-lock (fn [info]
                                                                (set lock-calls
                                                                     (+ lock-calls
                                                                        1))
                                                                (S.acquire-lock info))}
                                       ;; process B (`session send`) holds the lock
                                       release (assert (S.acquire-lock {:path s.path}))
                                       agent {:messages []}
                                       (a replayed) (session-lifecycle.start! {:continue? true}
                                                                              agent
                                                                              backend)
                                       b (assert (S.open-existing s.path))]
                                   (S.append a (types.user-message "A2"))
                                   (S.append a
                                             (types.assistant-message {:content [(types.tool-call-block "call-A"
                                                                                                        :bash
                                                                                                        {})]
                                                                       :stop-reason :tool-use}))
                                   (S.append b (types.user-message "B prompt"))
                                   (S.append b (text "B reply"))
                                   (S.append a
                                             (types.tool-result-message {:tool-call-id "call-A"
                                                                         :tool-name :bash
                                                                         :content [(types.text-block "ok")]}))
                                   (S.close a)
                                   (S.close b)
                                   (release)
                                   (and (not= a nil) (= replayed 2)
                                        (= lock-calls 0)
                                        (= "user:text assistant:text user:text assistant:tool_use user:text assistant:text user:tool_result"
                                           (wire-shape (am.convert-messages (S.load s.path)
                                                                            nil))))))))))))
