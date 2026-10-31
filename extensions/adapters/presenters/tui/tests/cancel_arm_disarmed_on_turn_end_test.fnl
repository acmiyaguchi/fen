;; Regression for #636 (spec/scheduler, `cancelArmMatchesTurn`, `forceQuitOnlyOnArmedTurn`):
;; the Ctrl-C cancel arm is disarmed when the cancelled turn ends, so a turn started
;; in the same on-tick (e.g. reload-request drain) does not inherit the armed state
;; and is not force-quit by a subsequent Ctrl-C.

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub!))
(local default-peek tb.peek_event)

(local ext-api (require :fen.core.extensions.test_api))
(local state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))
(local reload-request (require :fen.reload_request))

(tui.register (ext-api.make-runtime-api :tui))

(fn key [k]
  {:type tb.EVENT_KEY :key k :ch 0 :mod 0})

(fn no-event []
  (values nil "no event" tb.ERR_NO_EVENT))

(fn snapshot [rs peeks]
  {: peeks
   :turn-id rs.turn-id
   :busy? rs.busy?
   :cancel-pressed? state.cancel-pressed?
   :pending-quit? state.pending-quit?})

(fn start-turn! [rs body]
  (set rs.turn-id (+ rs.turn-id 1))
  (set rs.busy? true)
  (set rs.turn (coroutine.create body)))

(fn run-scenario [queue-reload?]
  "Real M.run + real input Ctrl-C ladder + real reload_request queue. on-tick
   copies interactive.fnl's order: resume the turn, on death clear busy?/turn,
   then drain a queued reload at the idle boundary. Peeks: none, Ctrl-C, none,
   Ctrl-C, then Ctrl-D. Returns the state seen at peek 5 (or at exit if the
   loop quit earlier)."
  (let [rs {:busy? false :turn nil :turn-id 0 :cancel-requested? false}
        script [:none :ctrl-c :none :ctrl-c]
        agent-turn (fn []
                     ;; The agent calls the `reload` tool mid-turn; it stays queued while busy.
                     (when queue-reload?
                       (assert (reload-request.enqueue! rs
                                                        {:scope :reload
                                                         :reason "agent asked"})))
                     (while true
                       (coroutine.yield)
                       ;; make-yield: an agent turn observes cancel at the first resume after the request.
                       (when rs.cancel-requested?
                         (error "cancelled"))))
        reload-turn (fn []
                      ;; /reload's plain yields never check cancel.
                      (for [_ 1 50]
                        (coroutine.yield)))
        on-tick (fn []
                  (when rs.turn
                    (let [(ok? _) (coroutine.resume rs.turn)]
                      (when (or (not ok?) (= (coroutine.status rs.turn) :dead))
                        (set rs.busy? false)
                        (set rs.turn nil)
                        (set rs.cancel-requested? false))))
                  (when (and (not rs.busy?) (not rs.turn))
                    (reload-request.drain! rs
                                           (fn [_request]
                                             (start-turn! rs reload-turn)))))
        on-cancel (fn []
                    (when rs.busy?
                      (set rs.cancel-requested? true)))
        is-busy? (fn [] rs.busy?)]
    (var peeks 0)
    (var at-end nil)
    (set tb.peek_event (fn [_timeout]
                         (set peeks (+ peeks 1))
                         (let [step (. script peeks)]
                           (if (= step :none) (no-event) (= step :ctrl-c)
                               (key tb.KEY_CTRL_C)
                               (do
                                 (when (= at-end nil)
                                   (set at-end (snapshot rs peeks)))
                                 (key tb.KEY_CTRL_D))))))
    (start-turn! rs agent-turn)
    (tui.run (fn [_line] nil) on-tick on-cancel is-busy? (fn [] rs.turn))
    (or at-end (snapshot rs peeks))))

(describe "Ctrl-C arm outlives its turn (#636)"
          (fn []
            (before_each (fn []
                           (tui-test.reset-state!)))
            (after_each (fn []
                          (set tb.peek_event default-peek)
                          (tui-test.reset-state!)))
            (it "a reload queued by the cancelled turn starts in the same tick and the next Ctrl-C does not force-quit"
                (fn []
                  ;; Control: no queued reload. The arm clears when turn A ends; the second Ctrl-C (idle) only arms the two-press quit.
                  (let [ctl (run-scenario false)]
                    (assert.are.same {:peeks 5
                                      :turn-id 1
                                      :busy? false
                                      :cancel-pressed? false
                                      :pending-quit? true}
                                     ctl))
                  (tui-test.reset-state!)
                  ;; Fixed: the queued reload starts turn 2 in the tick that killed turn 1;
                  ;; the arm is disarmed so Ctrl-C #2 arms cancel on turn 2 instead of force-quitting.
                  (let [got (run-scenario true)]
                    (assert.are.same {:peeks 5
                                      :turn-id 2
                                      :busy? true
                                      :cancel-pressed? true
                                      :pending-quit? false}
                                     got))))))
