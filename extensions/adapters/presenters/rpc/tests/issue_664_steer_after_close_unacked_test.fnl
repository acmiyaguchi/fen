;; Known-bug probe for #664 (child half): a steer that lands in the same poll
;; batch as the `close` that ends the run is never answered: `poll-controls!`
;; stops at exit, so the steer gets no control-ack and no drop notice.
;; See spec/wire/FINDINGS.md (#664).

(local test-api (require :fen.core.extensions.test_api))
(local register-registry (require :fen.core.extensions.register))
(local events (require :fen.core.extensions.events))
(local agent-mod (require :fen.core.agent))
(local types (require :fen.core.types))
(local turn-lifecycle (require :fen.turn_lifecycle))
(local wire (require :fen.util.wire))
(local mock (require :fen.extensions.provider_mock.mock_provider))
(local steering (require :fen.extensions.steering.service))
(local rpc (require :fen.extensions.rpc))
(local {: known-bug} (require :fen.testing))

(local RUN "run-1")
(local MAX-TICKS 2000)

(fn register-mock! []
  (let [p {}]
    (each [k v (pairs mock)] (tset p k v))
    (set p.name :mock)
    (register-registry.register :provider p :test)))

(fn slow-tool [name yields]
  "Coop-aware tool: yields YIELDS times while running."
  {:name name
   :label name
   :description name
   :parameters {:type :object :properties {}}
   :execute (fn [_args _ctx yield-fn]
              (for [_ 1 yields]
                (when yield-fn (yield-fn)))
              {:content [(types.text-block (.. name " done"))]})})

(fn make-state [script tools record]
  (let [agent (agent-mod.make-agent {:provider-name :mock
                                     :model "mock"
                                     :api-key :test
                                     :tools tools
                                     :on-event (fn [ev] (events.emit ev))
                                     :get-steering (fn []
                                                     (steering.get-steering))
                                     :get-follow-up (fn []
                                                      (steering.get-follow-up))
                                     :provider-options {:mock-script script
                                                        :mock-record record}})]
    {:agent agent :opts {}}))

(fn make-on-tick [state]
  "Mirror of the interactive runtime tick: one resume per tick."
  (fn []
    (when state.turn
      (let [(ok? value) (coroutine.resume state.turn)]
        (when (or (not ok?) (= (coroutine.status state.turn) :dead))
          (if ok? (set state.turn-result value) (set state.turn-error value))
          (set state.busy? false)
          (set state.turn nil)
          (set state.cancel-requested? false)
          (turn-lifecycle.emit-complete! state ok? value))))))

(fn make-parent [control-path event-path]
  "Scripted fake parent. `seen` holds every validated wire event so far."
  (let [parent {:seen []
                :reader (wire.line-reader event-path)
                :receiver (wire.receiver :event)
                :sender (wire.sender :control RUN)}]
    (fn parent.pump! []
      (let [(lines) (wire.read-lines! parent.reader)]
        (each [_ line (ipairs lines)]
          (let [(msg rej) (wire.receive! parent.receiver line)]
            (assert (= nil rej) (.. "invalid wire event: " line))
            (table.insert parent.seen msg)))))

    (fn parent.send! [typ ?payload]
      (let [(line rej) (wire.next! parent.sender typ ?payload)
            f (assert (io.open control-path :a))]
        (assert line (tostring (?. rej :reason)))
        (f:write line "\n")
        (f:close)
        parent.sender.seq))

    (fn parent.find [pred]
      (var found nil)
      (each [_ ev (ipairs parent.seen) &until found]
        (when (pred ev) (set found ev)))
      found)

    (fn parent.wait-type [typ]
      (parent.pump!)
      (while (not (parent.find #(= $1.type typ)))
        (coroutine.yield)
        (parent.pump!)))

    (fn parent.count [pred]
      (accumulate [n 0 _ ev (ipairs parent.seen)]
        (if (pred ev) (+ n 1) n)))

    (fn parent.acks [ref]
      (parent.count #(and (= $1.type :control-ack) (= $1.ref ref))))

    parent))

(fn run-child [opts]
  "Run the real rpc presenter to exit (or error) while OPTS.script plays the
   parent between ticks. OPTS.before-run (fn [ctx]) runs after rpc.init.
   Returns {:ok? :err :parent :record}; temp files are always removed."
  (let [control-path (os.tmpname)
        event-path (os.tmpname)
        _ (do
            (os.remove event-path)
            (io.close (io.open control-path :w)))
        record []
        state (make-state opts.mock opts.tools record)
        parent (make-parent control-path event-path)
        script (coroutine.create (fn [] (opts.script parent)))
        ticks {:n 0}
        clock {:now 1000}
        ctx {: state
             :on-tick (make-on-tick state)
             :wire {: control-path
                    : event-path
                    :run RUN
                    :now (fn [] clock.now)
                    :sleep (fn [_ms]
                             (set ticks.n (+ ticks.n 1))
                             (set clock.now (+ clock.now 1))
                             (assert (< ticks.n MAX-TICKS) "child did not exit")
                             (when (not= (coroutine.status script) :dead)
                               (let [(ok? err) (coroutine.resume script)]
                                 (assert ok? err))))}}
        (ok? err) (pcall (fn []
                           (rpc.init ctx)
                           (when opts.before-run (opts.before-run ctx))
                           (rpc.run ctx)))]
    (when (not ok?) (pcall rpc.shutdown ctx))
    (parent.pump!)
    (wire.close-reader! parent.reader)
    (os.remove control-path)
    (os.remove event-path)
    {: ok? : err : parent : record}))

(fn reset! []
  (test-api.reset!)
  (register-mock!)
  (steering.clear-queues!))

(describe "#664 rpc child: a steer batched after close"
          (fn []
            (before_each reset!)
            (it "is skipped unanswered once close exits the run"
                (fn []
                  (known-bug 664
                             (fn []
                               (let [r (run-child {:mock ["answer"]
                                                   :tools []
                                                   :script (fn [p]
                                                             (p.wait-type :ready)
                                                             (p.send! :prompt
                                                                      {:text "work"})
                                                             (p.wait-type :turn-complete)
                                                             ;; one batch: close, then steer
                                                             (p.send! :close {})
                                                             (p.send! :steer
                                                                      {:text "late steer"}))})
                                     p r.parent]
                                 (assert r.ok? r.err)
                                 (and (= :done
                                         (?. (p.find #(= $1.type :exit))
                                             :status))
                                      (= 1 (p.acks 2)) (= 0 (p.acks 3))
                                      (= 0 (p.count #(= $1.type :info)))))))))))
