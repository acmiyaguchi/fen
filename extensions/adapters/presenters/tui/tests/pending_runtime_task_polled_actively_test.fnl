;; Regression for #637 (spec/scheduler, `pendingWorkPolledActively`):
;; a pending runtime-tick task (e.g. decide ask-async!) is polled at the active
;; 30 ms cadence while the main turn is idle, rather than the 300 ms idle timeout.

(local {: package-loaded-snapshot : restore-package-loaded!}
       (require :fen.testing))

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub!))
(local default-peek tb.peek_event)

(local ext-api (require :fen.core.extensions.test_api))
(local ext-state (require :fen.core.extensions.state))
(local events (require :fen.core.extensions.events))
(local json (require :fen.util.json))
(local state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))

(local DECIDE-MODULES [:fen.util.http
                       :fen.extensions.decide
                       :fen.extensions.decide.service
                       :fen.extensions.decide.jev
                       :fen.extensions.decide.openai])

(local QUESTIONS {:a {:type :noul
                      :instructions "Is the task finished?"
                      :criteria {:true "The task is finished."
                                 :false "Work remains."}}})

(local OK-BODY
       (json.encode {:model "typesafe/jev-1.13-20260917"
                     :answers {:a {:type :noul :noul 0.99}}}))

;; The task yields 3 times inside the transport, so it needs 4 resumes to finish.
(local TRANSPORT-YIELDS 3)

(var saved-modules nil)

(fn load-decide! []
  "Load the real decide extension over a mocked, cooperative transport and
   register the TUI after it (test-api.reset! wipes bus handlers)."
  (ext-api.reset!)
  (each [_ name (ipairs DECIDE-MODULES)]
    (tset package.loaded name nil))
  (tset package.loaded :fen.util.http
        {:request (fn [req]
                    (for [_ 1 TRANSPORT-YIELDS]
                      (req.yield))
                    {:status 200 :body OK-BODY :headers {}})})
  (let [store (require :fen.extensions.decide.state)]
    (set store.api nil)
    (set store.tasks []))
  (tset ext-state.providers :openrouter
        {:api :openrouter-completions :api-key "sk-test-not-real"})
  (let [manifest (require :fen.extensions.decide.manifest)
        api (ext-api.make-runtime-api :decide manifest)
        decide (require :fen.extensions.decide)]
    (set api.settings {:extension (fn [] {})})
    (set api.log (fn [_level _msg] nil))
    (decide.register api))
  (tui.register (ext-api.make-runtime-api :tui))
  (values (require :fen.extensions.decide.service)
          (require :fen.extensions.decide.state)))

(describe "pending runtime-tick work polled actively (#637)"
          (fn []
            (before_each (fn []
                           (set saved-modules
                                (package-loaded-snapshot DECIDE-MODULES))
                           (tui-test.reset-state!)
                           (set state.tb-initialized? true)))
            (after_each (fn []
                          (set tb.peek_event default-peek)
                          (set state.tb-initialized? false)
                          (tui-test.reset-state!)
                          (ext-api.reset!)
                          (let [store (require :fen.extensions.decide.state)]
                            (set store.api nil)
                            (set store.tasks []))
                          (restore-package-loaded! saved-modules)))
            (it "M.run peeks with the active 30 ms timeout while a decide task is pending and the main turn is idle"
                (fn []
                  (let [(service store) (load-decide!)
                        done []
                        pending-timeouts []]
                    (assert.is_true (service.enabled?))
                    ;; Control: a busy main turn polls actively.
                    (assert.are.equal 30
                                      (tui.peek-timeout-ms (fn []
                                                             true)))
                    (service.ask-async! {} QUESTIONS
                                        (fn [answers]
                                          (table.insert done
                                                        answers)))
                    (assert.are.equal 1 (length store.tasks))
                    (var peeks 0)
                    (var ticks 0)
                    (set tb.peek_event
                         (fn [timeout]
                           (set peeks (+ peeks 1))
                           (when (> (length store.tasks) 0)
                             (table.insert pending-timeouts
                                           timeout))
                           (if (or (> (length done) 0)
                                   (> peeks 20))
                               {:type tb.EVENT_KEY
                                :key tb.KEY_CTRL_D
                                :ch 0
                                :mod 0}
                               (values nil "no event"
                                       tb.ERR_NO_EVENT))))
                    ;; on-tick emits :runtime-tick like interactive.fnl; decide's real handler pumps the task.
                    (tui.run (fn [_line] nil)
                             (fn []
                               (set ticks (+ ticks 1))
                               (events.emit {:type :runtime-tick
                                             :busy? false
                                             :agent {}}))
                             (fn [] nil)
                             (fn []
                               false))
                    ;; The task really was driven by the loop: 4 ticks, finished once with answers.
                    (assert.are.equal (+ TRANSPORT-YIELDS 1) ticks)
                    (assert.are.equal 1 (length done))
                    (assert.are.equal 0.99 (. done 1 :a :noul))
                    (assert.are.equal 0 (length store.tasks))
                    (assert.are.equal (+ TRANSPORT-YIELDS 1)
                                      (length pending-timeouts))
                    ;; Fixed: every peek with pending work used the active 30 ms timeout.
                    (each [_ t (ipairs pending-timeouts)]
                      (assert.are.equal 30 t)))))))
