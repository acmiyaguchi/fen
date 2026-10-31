;; auth.json writes never expose tokens to other users (#615, fixed in #605):
;; the temp file is created owner-only before any byte is written, a failed
;; write removes it, and a new auth directory is created owner-only.
;; Spec: spec/auth (secretsPrivate).
;; io.open is wrapped to observe the real save on a temp path at the moment
;; the temp file is opened for writing. POSIX permission bits only; the
;; checks are skipped on Windows. No real credentials.
(local h (require :fen.testing))
(local lfs (require :lfs))

(local storage-name :fen.extensions.provider_openai.openai_codex_keychain)

(local posix? (not= (string.sub package.config 1 1) "\\"))

(fn leftovers [dir]
  (let [out []]
    (each [name (lfs.dir dir)]
      (when (string.match name "^auth%.json%.")
        (when (not= name "auth.json.lock")
          (table.insert out name))))
    out))

(local SECRETS {:openai-codex {:type :oauth
                               :access "SECRET-ACCESS"
                               :refresh "SECRET-REFRESH"}})

(describe "auth.json private writes"
          (fn []
            (var tmp nil)
            (var real-open nil)
            (before_each (fn []
                           (set tmp (h.make-tmpdir))
                           (set real-open io.open)))
            (after_each (fn []
                          (set io.open real-open)
                          (when tmp (h.rmtree tmp))))
            (it "creates the temp file 0600 and empty before writing the tokens"
                (fn []
                  (when posix?
                    (let [storage (require storage-name)
                          dir (.. tmp "/agent")
                          auth-path (.. dir "/auth.json")
                          seen {}]
                      (set io.open
                           (fn [p mode]
                             (when (and (= (string.sub p 1
                                                       (+ (length auth-path) 1))
                                           (.. auth-path "."))
                                        (not= p (.. auth-path ".lock")))
                               (set seen.tmp p)
                               (set seen.mode (lfs.attributes p :permissions))
                               (set seen.size (lfs.attributes p :size)))
                             (real-open p mode)))
                      (storage.save SECRETS auth-path)
                      (set io.open real-open)
                      (assert.is_string seen.tmp)
                      (assert.equal "rw-------" seen.mode)
                      (assert.equal 0 seen.size)
                      (assert.equal "rw-------"
                                    (lfs.attributes auth-path :permissions))
                      (assert.equal "rwx------"
                                    (lfs.attributes dir :permissions))
                      (assert.same [] (leftovers dir))
                      (assert.equal "SECRET-REFRESH"
                                    (. (storage.get :openai-codex auth-path)
                                       :refresh))))))
            (it "removes the token-bearing temp file when the write fails"
                (fn []
                  (let [storage (require storage-name)
                        auth-path (.. tmp "/auth.json")]
                    (set io.open
                         (fn [p mode]
                           (if (and (= (string.sub p 1 (+ (length auth-path) 1))
                                       (.. auth-path "."))
                                    (not= p (.. auth-path ".lock")))
                               (let [f (real-open p mode)]
                                 ;; a partial write, then the failure
                                 {:write (fn [_ s]
                                           (f:write (string.sub s 1 10))
                                           (error :disk-full 0))
                                  :close (fn [_] (f:close))})
                               (real-open p mode))))
                    (let [(ok? err) (pcall storage.save SECRETS auth-path)]
                      (set io.open real-open)
                      (assert.is_false ok?)
                      (assert.truthy (string.find (tostring err) "disk-full" 1
                                                  true)))
                    (assert.same [] (leftovers tmp))
                    (assert.is_nil (storage.get :openai-codex auth-path)))))))
