;; Regression for #638 (spec/serve, `resolutionInScope`): an idle-only command
;; (/resume, /model) checks that the session remains idle when its picker resolves;
;; if a turn started while the picker was open, the command refuses to apply rather
;; than swapping state under the running turn.

(local test-api (require :fen.core.extensions.test_api))
(local command-registry (require :fen.core.extensions.register.command))
(local extension-state (require :fen.core.extensions.state))
(local steering (require :fen.extensions.steering.service))

(fn reset! []
  (steering.clear-queues!)
  (steering.install-runtime! nil)
  (test-api.reset!))

(describe "idle-only command refuses after turn starts (#638)"
          (fn []
            (before_each reset!)
            (after_each reset!)
            (it "/resume does not swap agent or session if a turn started while its picker was open"
                (fn []
                  (let [api (test-api.make-runtime-api :sessions)
                        mod (require :fen.extensions.sessions.commands.session)
                        old-agent {:messages []}
                        during-select {}
                        emitted []
                        _ (api.on :error (fn [ev] (table.insert emitted ev)))
                        state {:busy? false
                               :agent old-agent
                               :session "/s/current.jsonl"
                               :opts {}
                               :on-event (fn [] nil)
                               :agent-extra {}
                               :list-sessions (fn []
                                                [{:path "/s/other.jsonl"
                                                  :id :other}])
                               :find-session (fn [_cwd target] target)
                               :load-session (fn []
                                               [{:role :user :content "hi"}])
                               :open-existing-session (fn [p] p)
                               :close-session (fn [] nil)
                               :make-agent-from-opts (fn [] {:messages []})
                               :make-flush (fn [] (fn [] nil))}]
                    (mod.register api)
                    ;; The interactive runtime's bridge; starting a follow-up marks the turn running.
                    (steering.install-runtime! {:is-idle? (fn []
                                                            (and (not state.busy?)
                                                                 (not state.turn)))
                                                :start-follow-up! (fn [_text]
                                                                    (set state.busy? true)
                                                                    (set state.turn :follow-up)
                                                                    (set state.turn-id 1))})
                    ;; The picker: while it is open, a turn starts.
                    (set extension-state.ui.slot
                         {:select (fn [opts]
                                    (api.enqueue :follow-up "queued prompt"
                                                 {:start-if-idle? true})
                                    (steering.start-idle-follow-up!)
                                    (set during-select.busy? state.busy?)
                                    (. opts.choices 1))})
                    (command-registry.dispatch "/resume" state)
                    (assert.is_true during-select.busy?)
                    (assert.is_true state.busy?)
                    ;; Fixed: session and agent were NOT swapped under the running turn.
                    (assert.are.equal "/s/current.jsonl" state.session)
                    (assert.are.equal old-agent state.agent)
                    ;; An error event was emitted explaining the refusal.
                    (assert.is_true (> (length emitted) 0))
                    (assert.is_true (not= nil (string.find (. emitted 1 :error)
                                                           "cannot resume session: agent became busy"
                                                           1 true))))))))
