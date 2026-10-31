;; Known-bug probe for #632: the rpc child treats only a thrown Lua error as
;; a failed turn. After a provider error (here quota exhaustion) `finish!`
;; emits `result` with the assistant's "[error] ..." text as final-text and
;; then `exit done`, and `run` returns 0; error-details are not carried.
;; See spec/presenters/FINDINGS.md (#632).

(local test-api (require :fen.core.extensions.test_api))
(local register-registry (require :fen.core.extensions.register))
(local events (require :fen.core.extensions.events))
(local agent-mod (require :fen.core.agent))
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

(fn make-state [mock-script]
  (let [state {:opts {}
               :session {:id :s}
               :flush (fn [] nil)
               :make-flush (fn [] (fn [] nil))}
        agent (agent-mod.make-agent {:provider-name :mock
                                     :model "mock"
                                     :api-key :test
                                     :on-event (fn [ev] (events.emit ev))
                                     :get-steering (fn []
                                                     (steering.get-steering))
                                     :get-follow-up (fn []
                                                      (steering.get-follow-up))
                                     :provider-options {: mock-script}})]
    (set state.agent agent)
    state))

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

(fn run-child [mock-script script-fn]
  "Run the real rpc presenter to exit while SCRIPT-FN plays the parent
   between ticks. Returns {:ok? :code :parent}; temp files are removed."
  (let [control-path (os.tmpname)
        event-path (os.tmpname)
        _ (do
            (os.remove event-path)
            (io.close (io.open control-path :w)))
        state (make-state mock-script)
        parent (make-parent control-path event-path)
        script (coroutine.create (fn [] (script-fn parent)))
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
        (ok? code) (pcall (fn []
                            (rpc.init ctx)
                            (rpc.run ctx)))]
    (when (not ok?) (pcall rpc.shutdown ctx))
    (parent.pump!)
    (wire.close-reader! parent.reader)
    (os.remove control-path)
    (os.remove event-path)
    {: ok? : code : parent}))

(describe "#632 rpc child outcome after a failed turn"
          (fn []
            (before_each (fn []
                           (test-api.reset!)
                           (register-mock!)
                           (steering.clear-queues!)))
            (after_each (fn [] (test-api.reset!)))
            (it "exits done with code 0 and an [error] final-text after a quota error"
                (fn []
                  (known-bug 632
                             (fn []
                               (let [r (run-child (fn [_req]
                                                    {:error "usage_limit_reached: quota"})
                                                  (fn [p]
                                                    (p.wait-type :ready)
                                                    (p.send! :prompt
                                                             {:text "go"})
                                                    (p.wait-type :turn-complete)
                                                    (p.send! :close {})))
                                     p r.parent
                                     tc (p.find #(= $1.type :turn-complete))
                                     result (p.find #(= $1.type :result))
                                     exit (p.find #(= $1.type :exit))
                                     final (tostring (?. result :final-text))]
                                 (assert r.ok? (tostring r.code))
                                 (and (= "error"
                                         (tostring (?. tc :stop-reason)))
                                      (= "error"
                                         (tostring (?. result :stop-reason)))
                                      (= "[error] " (string.sub final 1 8))
                                      (= nil (?. result :error-details))
                                      (= "done" (tostring (?. exit :status)))
                                      (= 0 r.code)))))))))
