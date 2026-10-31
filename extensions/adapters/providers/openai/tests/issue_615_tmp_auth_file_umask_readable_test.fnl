;; #615: keychain.save writes the tokens into a tmp file created with the
;; process umask and only chmods it 600 just before the rename; a crash in
;; between leaves the token-bearing tmp file behind.
;; Spec: spec/auth (w615TmpWorldReadableTest).
;; io.open and os.execute are wrapped to observe the real save on a temp
;; path: at the moment `chmod 600 <tmp>` is invoked, the tmp already holds
;; the token and has the same mode as any file the umask produces (a control
;; file). A failing chmod (the closest observable stand-in for a kill at that
;; point) leaves the tmp file in place. No real credentials.
(local h (require :fen.testing))
(local {: known-bug} h)
(local lfs (require :lfs))

(local storage-name :fen.extensions.provider_openai.openai_codex_keychain)

(fn read-file [p]
  (let [f (io.open p :r)]
    (when f
      (let [text (f:read "*a")]
        (f:close)
        text))))

(describe "#615 auth.json tmp file permissions"
          (fn []
            (var tmp nil)
            (var real-execute nil)
            (before_each (fn []
                           (set tmp (h.make-tmpdir))
                           (set real-execute os.execute)))
            (after_each (fn []
                          (set os.execute real-execute)
                          (when tmp (h.rmtree tmp))))
            (it "the token sits in a umask-mode tmp file before chmod, and a crash there leaves it"
                (fn []
                  (known-bug 615
                             (fn []
                               (let [storage (require storage-name)
                                     auth-path (.. tmp "/auth.json")
                                     control (.. tmp "/control")
                                     _ (let [f (io.open control :w)]
                                         (f:write "x")
                                         (f:close))
                                     umask-mode (lfs.attributes control
                                                                :permissions)
                                     seen {}]
                                 ;; observe the tmp at its chmod, then fail there
                                 (set os.execute
                                      (fn [cmd]
                                        (let [target (string.match cmd
                                                                   "^chmod 600 '(.-)'")]
                                          (if (and target
                                                   (not= target auth-path))
                                              (do
                                                (set seen.tmp target)
                                                (set seen.mode
                                                     (lfs.attributes target
                                                                     :permissions))
                                                (set seen.text
                                                     (read-file target))
                                                (error :killed 0))
                                              (real-execute cmd)))))
                                 (let [(ok? err) (pcall storage.save
                                                        {:openai-codex {:type :oauth
                                                                        :access "SECRET-ACCESS"
                                                                        :refresh "SECRET-REFRESH"}}
                                                        auth-path)]
                                   (set os.execute real-execute)
                                   (let [leftover (and seen.tmp
                                                       (read-file seen.tmp))]
                                     (and (not ok?) (= err :killed)
                                          (not= nil seen.tmp)
                                          (= seen.mode umask-mode)
                                          (not= nil
                                                (string.find (or seen.text "")
                                                             "SECRET-REFRESH" 1
                                                             true))
                                          (not= nil leftover)
                                          (not= nil
                                                (string.find leftover
                                                             "SECRET-REFRESH" 1
                                                             true))
                                          (= nil (read-file auth-path))))))))))))
