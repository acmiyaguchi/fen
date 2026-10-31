;; #614: provider requests use the credentials pinned at agent construction;
;; once that access token expires every request is a terminal 401.
;; Spec: spec/auth (w614PinnedTokenExpires401Test) and
;; spec/auth/proofs/pinning (w614PinnedTokenExpires401Test).
;; The real list-models gets `:creds` the way main.fnl -> interactive.fnl
;; pass them (provider-options.creds). get-fresh-creds! is stubbed to return
;; a new token and HTTP is stubbed to accept only that token, so the bug
;; shows as: the stale token is sent, no re-resolution, authentication-failed.
;; The main.fnl/interactive.fnl wiring is a line trace (see FINDINGS).
(local h (require :fen.testing))
(local {: known-bug} h)

(local responses-name :fen.extensions.provider_openai.openai_codex_responses)
(local oauth-name :fen.extensions.provider_openai.openai_codex_oauth)
(local http-name :fen.util.http)

(describe "#614 pinned Codex credentials"
          (fn []
            (var saved nil)
            (var sent nil)
            (var fresh-calls 0)
            (before_each (fn []
                           (set saved {})
                           (each [_ name (ipairs [responses-name
                                                  oauth-name
                                                  http-name])]
                             (tset saved name (. package.loaded name)))
                           (set sent nil)
                           (set fresh-calls 0)
                           (tset package.loaded http-name
                                 {:request (fn [opts]
                                             (set sent
                                                  opts.headers.authorization)
                                             (if (= sent "Bearer NEW")
                                                 {:status 200
                                                  :headers {}
                                                  :body "{\"models\":[]}"}
                                                 {:status 401
                                                  :headers {}
                                                  :body "expired"}))})
                           (tset package.loaded oauth-name
                                 {:get-fresh-creds! (fn [_ _]
                                                      (set fresh-calls
                                                           (+ fresh-calls 1))
                                                      {:access "NEW"
                                                       :accountId "acc"
                                                       :expires (* (+ (os.time)
                                                                      3600)
                                                                   1000)})})
                           (tset package.loaded responses-name nil)))
            (after_each (fn []
                          (each [_ name (ipairs [responses-name
                                                 oauth-name
                                                 http-name])]
                            (tset package.loaded name (. saved name)))))
            (it "sends the expired pinned token and fails without re-resolving"
                (fn []
                  (known-bug 614
                             (fn []
                               (let [codex (require responses-name)
                                     (ok? err) (pcall codex.list-models
                                                      {:creds {:access "OLD"
                                                               :accountId "acc"
                                                               :expires 0}})]
                                 (and (not ok?) (= sent "Bearer OLD")
                                      (= fresh-calls 0)
                                      (= :authentication-failed
                                         (?. err :reason))))))))))
