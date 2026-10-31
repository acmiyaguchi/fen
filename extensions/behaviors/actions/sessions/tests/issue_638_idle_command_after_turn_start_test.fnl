;; Probe for #638 (spec/serve, issue.resolutionInScope): an idle-only command
;; acts after a turn starts under its open picker. command.dispatch checks
;; :idle-only? once, before the handler runs; /resume then blocks in
;; ui.select, and the overlay's tick (pump-background-ticks! -> on-tick)
;; runs steering.start-idle-follow-up!, which can start a turn. When the
;; picker returns, resume-session! swaps state.agent and state.session under
;; the running turn.

(local test-api (require :fen.core.extensions.test_api))
(local command-registry (require :fen.core.extensions.register.command))
(local extension-state (require :fen.core.extensions.state))
(local steering (require :fen.extensions.steering.service))
(local {: known-bug} (require :fen.testing))

(fn reset! []
  (steering.clear-queues!)
  (steering.install-runtime! nil)
  (test-api.reset!))

(describe "#638 idle-only command after a turn starts under its picker"
          (fn []
            (before_each reset!)
            (after_each reset!)
            (it "/resume swaps the agent and session under a turn started while its picker was open"
                (fn []
                  (known-bug 638
                             (fn []
                               (let [api (test-api.make-runtime-api :sessions)
                                     mod (require :fen.extensions.sessions.commands.session)
                                     old-agent {:messages []}
                                     during-select {}
                                     state {:busy? false
                                            :agent old-agent
                                            :session "/s/current.jsonl"
                                            :opts {}
                                            :on-event (fn [] nil)
                                            :agent-extra {}
                                            :list-sessions (fn []
                                                             [{:path "/s/other.jsonl"
                                                               :id :other}])
                                            :find-session (fn [_cwd target]
                                                            target)
                                            :load-session (fn []
                                                            [{:role :user
                                                              :content "hi"}])
                                            :open-existing-session (fn [p] p)
                                            :close-session (fn [] nil)
                                            :make-agent-from-opts (fn []
                                                                    {:messages []})
                                            :make-flush (fn []
                                                          (fn [] nil))}]
                                 (mod.register api)
                                 ;; The interactive runtime's bridge; starting a
                                 ;; follow-up marks the turn running, as
                                 ;; submit-user-turn! does.
                                 (steering.install-runtime! {:is-idle? (fn []
                                                                         (and (not state.busy?)
                                                                              (not state.turn)))
                                                             :start-follow-up! (fn [_text]
                                                                                 (set state.busy?
                                                                                      true)
                                                                                 (set state.turn
                                                                                      :follow-up)
                                                                                 (set state.turn-id
                                                                                      1))})
                                 ;; The picker: while it is open, an extension
                                 ;; (or, under #397, a remote client) enqueues a
                                 ;; prompt and the overlay's tick starts it.
                                 (set extension-state.ui.slot
                                      {:select (fn [opts]
                                                 (api.enqueue :follow-up
                                                              "queued prompt"
                                                              {:start-if-idle? true})
                                                 (steering.start-idle-follow-up!)
                                                 (set during-select.busy?
                                                      state.busy?)
                                                 (. opts.choices 1))})
                                 (command-registry.dispatch "/resume" state)
                                 (and (= true during-select.busy?)
                                      (= true state.busy?)
                                      (= "/s/other.jsonl" state.session)
                                      (not= old-agent state.agent)))))))))
