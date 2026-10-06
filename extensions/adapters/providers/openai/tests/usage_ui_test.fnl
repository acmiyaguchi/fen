;; User contract: quota is ambient for Codex only; /usage opens bounded detail,
;; demand refresh yields between ticks, paint never requests HTTP, Esc dismisses.
(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub! {:capture? true :cols 100 :rows 12}))
(set tb.KEY_ESC 27)
(tui-test.install-markdown-stub!)
(local test-api (require :fen.core.extensions.test_api))
(local tui-state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))
(local paint (require :fen.extensions.tui.paint))
(local input (require :fen.extensions.tui.input))
(local state (require :fen.extensions.provider_openai.usage_state))
(local module :fen.extensions.provider_openai.usage)
(local auth-name :fen.extensions.provider_openai.openai_codex_oauth)
(local http-name :fen.util.http)
(local storage-name :fen.extensions.provider_openai.openai_codex_keychain)

(describe "Codex quota presentation"
          (fn []
            (var usage nil)
            (var old-auth nil)
            (var old-http nil)
            (var old-storage nil)
            (var specs nil)
            (var handlers nil)
            (var requests 0)
            (var now nil)

            (fn windows []
              [{:name "rate_limit/primary_window"
                :used-percent 22
                :remaining-percent 78
                :length-seconds 18000
                :reset-at (+ now 6900)}
               {:name "rate_limit/secondary_window"
                :used-percent 5
                :remaining-percent 95
                :length-seconds 604800
                :reset-at (+ now 518400)}])

            (fn frame []
              (paint.paint-frame!)
              (tui-test.screen-lines tb))

            (fn toggle []
              ((. specs :command :handler) "" {:opts {:provider :openai-codex}}))

            (before_each (fn []
                           (set now (os.time))
                           (set old-auth (. package.loaded auth-name))
                           (set old-http (. package.loaded http-name))
                           (set old-storage (. package.loaded storage-name))
                           (tset package.loaded storage-name
                                 {:get (fn [_] nil)})
                           (tset package.loaded auth-name
                                 {:get-fresh-creds! (fn [_ opts] (opts.yield)
                                                      {:access "fake"
                                                       :accountId "fake"})})
                           (set requests 0)
                           (tset package.loaded http-name
                                 {:request (fn [opts]
                                             (set requests (+ requests 1))
                                             (opts.yield)
                                             {:status 404})})
                           (tset package.loaded module nil)
                           (set usage (require module))
                           (set state.cache-path false)
                           (set state.account-key nil)
                           (set state.loaded? false)
                           (set state.visible? false)
                           (set state.panel-unsupported? false)
                           (set state.refresh-co nil)
                           (set state.windows (windows))
                           (set state.retrieved-at now)
                           (set state.attempted-at now)
                           (set state.failure nil)
                           (test-api.reset!)
                           (tui-test.reset-state! {:cols 100 :rows 12})
                           (set tb.width-value 100)
                           (set tb.height-value 12)
                           (tui.register (test-api.make-runtime-api :tui))
                           (set tui-state.tb-initialized? true)
                           (set tui-state.status-info.provider :openai-codex)
                           (set tui-state.status-info.model :sol)
                           (paint.ensure-state-defaults!)
                           (set specs {})
                           (set handlers {})
                           (local api
                                  (test-api.make-runtime-api :provider_openai))
                           (usage.register {:emit api.emit
                                            :register (fn [kind spec]
                                                        (tset specs kind spec)
                                                        (api.register kind spec))
                                            :on (fn [event handler]
                                                  (tset handlers event handler)
                                                  (api.on event handler))})))
            (after_each (fn []
                          (test-api.reset!)
                          (tset package.loaded auth-name old-auth)
                          (tset package.loaded http-name old-http)
                          (tset package.loaded storage-name old-storage)
                          (tset package.loaded module nil)))
            (it "labels durations and percentages, degrades to the least remaining window"
                (fn []
                  (local snapshot (usage.snapshot))
                  (assert.same {:text "5h:78% 7d:95%" :style :status}
                               (usage.status snapshot 100 now))
                  (assert.equal "5h:78%"
                                (. (usage.status snapshot 50 now) :text))
                  (assert.equal "5h:78%"
                                (. (usage.status snapshot 34 now) :text))
                  (assert.equal "5h:78%"
                                (. (usage.status snapshot 8 now) :text))
                  (assert.equal "1h55m" (usage.relative 6900))
                  (assert.equal "6d" (usage.relative 518400))
                  (assert.equal "rate_limit/primary_window"
                                (usage.label {:name "rate_limit/primary_window"
                                              :length-seconds 1200}))
                  (assert.equal :status (usage.style 25 false))
                  (assert.equal :tool (usage.style 24 false))
                  (assert.equal :tool (usage.style 10 true))
                  (assert.equal :error (usage.style 9 true))
                  (assert.equal :dim (usage.style 78 true))
                  (set snapshot.status :stale)
                  (assert.equal "~5h:78%"
                                (. (usage.status snapshot 8 now) :text))
                  (tset snapshot.windows 1 :reset-at now)
                  (assert.equal "~5h:100%"
                                (. (usage.status snapshot 50 now) :text))
                  (assert.is_truthy (string.find (. (usage.rows snapshot 80 now)
                                                    2 :text)
                                                 "100%% left / reset"))))
            (it "shows the tightest window at 80 columns and both at 100 in the frame"
                (fn []
                  (toggle)
                  (set tui-state.tb-cols 80)
                  (set tb.width-value 80)
                  (local narrow (frame))
                  (assert.is_truthy (string.find (. narrow 1) "5h:78%%"))
                  (assert.is_nil (string.find (. narrow 1) "7d:95%%"))
                  (set tui-state.tb-cols 100)
                  (set tb.width-value 100)
                  (local lines (frame))
                  (assert.is_truthy (string.find (. lines 1) "5h:78%% 7d:95%%"))
                  (assert.equal "codex quota - updated 0s ago" (. lines 2))
                  (assert.equal "5h [###############-----] 78% left / resets 1h55m"
                                (. lines 3))
                  (assert.equal "7d [###################-] 95% left / resets 6d"
                                (. lines 4))
                  (assert.equal 0 requests)
                  (input.handle-key {:key 27 :ch 0 :mod 0} (fn [_]) nil
                                    (fn []
                                      false))
                  (assert.is_true tui-state.alt-pending?)
                  ;; The production presenter emits dismiss at the next idle boundary,
                  ;; after allowing Esc+key to disambiguate Alt input.
                  (tui-state.api.emit {:type :dismiss})
                  (assert.is_false state.visible?)
                  (assert.is_nil (string.find (. (frame) 2) "codex quota"))
                  (toggle)
                  (assert.is_true state.visible?)
                  (toggle)
                  (assert.is_nil (string.find (. (frame) 2) "codex quota"))))
            (it "renders stale age and failure without promising old percentages after reset"
                (fn []
                  (set state.retrieved-at (- now 7200))
                  (set state.failure :network)
                  (tset state.windows 1 :reset-at (- now 1))
                  (toggle)
                  (local lines (frame))
                  (assert.is_truthy (string.find (. lines 1)
                                                 "~5h:100%% 7d:95%%"))
                  (assert.equal "codex quota - stale, updated 2h ago / network"
                                (. lines 2))
                  (assert.is_truthy (string.find (. lines 3)
                                                 "100%% left / reset"))
                  (assert.equal 0 requests)))
            (it "explains unsupported and auth failures, clips narrow detail and hides non-Codex status"
                (fn []
                  (set state.windows [])
                  (set state.retrieved-at nil)
                  (set state.failure :auth)
                  (toggle)
                  (assert.equal "Quota unavailable: sign in to openai-codex."
                                (. (frame) 3))
                  (set state.failure :unsupported)
                  (assert.equal "Quota unavailable: unsupported by this account."
                                (. (frame) 3))
                  (assert.is_nil ((. specs :status :render) {:w 100
                                                             :status-info {:provider :openai-codex}}))
                  (set state.windows (windows))
                  (set state.retrieved-at now)
                  (set state.failure nil)
                  (assert.is_nil ((. specs :status :render) {:w 100
                                                             :status-info {:provider :openai}}))
                  (set tui-state.tb-cols 50)
                  (set tb.width-value 50)
                  (assert.equal "5h [##############----] 78% left / resets 1h55m"
                                (. (frame) 3))
                  (set tui-state.tb-cols 20)
                  (set tb.width-value 20)
                  (each [_ line (ipairs (frame))]
                    (assert.is_true (<= (length line) 20)))))
            (it "refreshes only on demand, cooperatively across ticks rather than during paint"
                (fn []
                  (set state.attempted-at nil)
                  (toggle)
                  (frame)
                  (assert.equal 0 requests)
                  ((. handlers :runtime-tick) {})
                  (assert.equal 0 requests)
                  (frame)
                  ((. handlers :runtime-tick) {})
                  (assert.equal 1 requests)
                  (frame)
                  ((. handlers :runtime-tick) {})
                  (assert.is_nil state.refresh-co)
                  (assert.equal :unsupported state.failure)
                  (toggle)
                  (toggle)
                  ((. handlers :runtime-tick) {})
                  (assert.equal 1 requests)))))
