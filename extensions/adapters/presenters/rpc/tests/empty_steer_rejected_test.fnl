;; Regression for #666: an empty steer is rejected with an ack, so it never
;; blinds ref matching for later steers.

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

    (fn parent.raw! [line]
      (let [f (assert (io.open control-path :a))]
        (f:write line "\n")
        (f:close)))

    (fn parent.send! [typ ?payload]
      (let [(line _rej) (wire.next! parent.sender typ ?payload)
            line (or line
                     (let [json (require :fen.util.json)]
                       (set parent.sender.seq (+ parent.sender.seq 1))
                       (json.encode {:type typ
                                     :run RUN
                                     :seq parent.sender.seq
                                     :payload ?payload})))]
        (parent.raw! line)
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
                    :result-path opts.result-path
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

(describe "#666 rpc child: an empty steer"
          (fn []
            (before_each reset!)
            (it "is rejected and the next steer keeps its ref"
                (fn []
                  (let [r (run-child {:mock [{:tool-call {:id "c1" :name :slow}}
                                             "steered answer"]
                                      :tools [(slow-tool :slow 3)]
                                      :script (fn [p]
                                                (p.wait-type :ready)
                                                (p.send! :prompt {:text "work"})
                                                (p.wait-type :tool-call)
                                                (p.send! :steer {:text ""})
                                                (p.send! :steer
                                                         {:text "real steer"})
                                                (p.wait-type :turn-complete)
                                                (p.send! :close {}))})
                        p r.parent
                        ack (fn [ref]
                              (?. (p.find #(and (= $1.type :control-ack)
                                                (= $1.ref ref)))
                                  :status))
                        injected (p.find #(and (= $1.type :steering-injected)
                                               (= $1.text "real steer")))]
                    (assert r.ok? r.err)
                    (assert (= :rejected (ack 2)))
                    (assert (= :accepted (ack 3)))
                    (assert (not= nil injected))
                    (assert (= 3 injected.ref))
                    (assert (= 0 (p.count #(= $1.type :info)))))))))
