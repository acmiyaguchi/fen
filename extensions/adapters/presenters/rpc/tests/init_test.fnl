;; Conformance kit, child half (#516): a scripted fake parent drives the real
;; rpc presenter, the real cooperative agent loop, the steering queues, and
;; the mock provider, speaking only the wire protocol through the control and
;; event files.

(local test-api (require :fen.core.extensions.test_api))
(local register-registry (require :fen.core.extensions.register))
(local events (require :fen.core.extensions.events))
(local agent-mod (require :fen.core.agent))
(local types (require :fen.core.types))
(local turn-lifecycle (require :fen.turn_lifecycle))
(local json (require :fen.util.json))
(local wire (require :fen.util.wire))
(local mock (require :fen.extensions.provider_mock.mock_provider))
(local steering (require :fen.extensions.steering.service))
(local turn-submit (require :fen.turn_submit))
(local rpc (require :fen.extensions.rpc))

(local RUN "run-1")
(local MAX-TICKS 2000)

(fn register-mock! []
  (let [p {}]
    (each [k v (pairs mock)] (tset p k v))
    (set p.name :mock)
    (register-registry.register :provider p :test)))

(fn slow-tool [name yields log ?output]
  "Coop-aware tool: yields YIELDS times while running, recording progress."
  {:name name :label name :description name
   :parameters {:type :object :properties {}}
   :execute (fn [_args _ctx yield-fn]
              (table.insert log :started)
              (for [_ 1 yields]
                (when yield-fn (yield-fn)))
              (table.insert log :finished)
              {:content [(types.text-block (or ?output (.. name " done")))]})})

(fn make-state [script tools record]
  (let [agent (agent-mod.make-agent
                {:provider-name :mock :model "mock" :api-key :test
                 :tools tools
                 :on-event (fn [ev] (events.emit ev))
                 :get-steering (fn [] (steering.get-steering))
                 :get-follow-up (fn [] (steering.get-follow-up))
                 :provider-options {:mock-script script :mock-record record}})]
    {:agent agent :opts {}}))

(fn make-on-tick [state]
  "Mirror of the interactive runtime tick: one resume per tick, then the
   usual completion bookkeeping."
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
                : control-path
                :offset 0
                :receiver (wire.receiver :event)
                :sender (wire.sender :control RUN)}]
    (fn parent.pump! []
      (let [(lines offset) (wire.read-lines event-path parent.offset)]
        (set parent.offset offset)
        (each [_ line (ipairs lines)]
          (let [(msg rej) (wire.receive! parent.receiver line)]
            (assert (= nil rej) (.. "invalid wire event: " line " -> "
                                     (tostring (?. rej :reason))))
            (table.insert parent.seen msg)))))
    (fn parent.raw! [line]
      (let [f (assert (io.open control-path :a))]
        (f:write line "\n")
        (f:close)))
    (fn parent.send! [typ ?payload]
      (let [(line rej) (wire.next! parent.sender typ ?payload)]
        (assert line (tostring (?. rej :reason)))
        (parent.raw! line)
        parent.sender.seq))
    (fn parent.find [pred]
      (var found nil)
      (each [_ ev (ipairs parent.seen) &until found]
        (when (pred ev) (set found ev)))
      found)
    (fn parent.wait [pred]
      (parent.pump!)
      (while (not (parent.find pred))
        (coroutine.yield)
        (parent.pump!))
      (parent.find pred))
    (fn parent.wait-type [typ]
      (parent.wait (fn [ev] (= ev.type typ))))
    (fn parent.ack [ref]
      (parent.find (fn [ev] (and (= ev.type :control-ack) (= ev.ref ref)))))
    (fn parent.wait-ack [ref]
      (parent.wait (fn [ev] (and (= ev.type :control-ack) (= ev.ref ref)))))
    (fn parent.types []
      (icollect [_ ev (ipairs parent.seen)] ev.type))
    parent))

(fn run-child [opts]
  "Run the presenter to exit while OPTS.script (fn [parent]) plays the parent
   between ticks. Returns {:code :parent :record :state}."
  (let [control-path (os.tmpname)
        event-path (os.tmpname)
        _ (do (os.remove event-path) (io.close (io.open control-path :w)))
        record []
        state (make-state opts.mock opts.tools record)
        parent (make-parent control-path event-path)
        script (coroutine.create (fn [] (opts.script parent)))
        ticks {:n 0}
        clock {:now 1000}
        ctx {:state state
             :on-tick (let [base (make-on-tick state)]
                        (if opts.wrap-tick (opts.wrap-tick state base) base))
             :wire {: control-path : event-path :run RUN
                    :deadline opts.deadline
                    :now (fn [] clock.now)
                    :sleep (fn [_ms]
                             (set ticks.n (+ ticks.n 1))
                             (set clock.now (+ clock.now 1))
                             (assert (< ticks.n MAX-TICKS) "child did not exit")
                             (when (not= (coroutine.status script) :dead)
                               (let [(ok? err) (coroutine.resume script)]
                                 (assert ok? err))))}}
        code (rpc.run ctx)]
    (parent.pump!)
    (os.remove control-path)
    (os.remove event-path)
    {: code : parent : record : state}))

(fn count-type [parent typ]
  (accumulate [n 0 _ ev (ipairs parent.seen)]
    (if (= ev.type typ) (+ n 1) n)))

(fn last-event [parent]
  (. parent.seen (length parent.seen)))

(fn user-texts [messages]
  (let [out []]
    (each [_ m (ipairs messages)]
      (when (= m.role :user)
        (table.insert out (if (= (type m.content) :string)
                              m.content
                              (types.assistant-text m)))))
    out))

(fn context-text [call]
  (let [parts []]
    (each [_ m (ipairs call.context.messages)]
      (if (= (type m.content) :string)
          (table.insert parts m.content)
          (each [_ b (ipairs (or m.content []))]
            (when b.text (table.insert parts b.text)))))
    (table.concat parts "\n")))

(fn assert-closed-run! [result]
  "Every run ends with exactly one exit as the last line; `result` appears
   exactly once and only immediately before `exit done`."
  (let [parent result.parent
        exit (last-event parent)
        results (count-type parent :result)]
    (assert.are.equal :exit exit.type)
    (assert.are.equal 1 (count-type parent :exit))
    (if (= exit.status :done)
        (do (assert.are.equal 1 results)
            (assert.are.equal :result (. parent.seen (- (length parent.seen) 1) :type))
            (assert.are.equal 0 result.code))
        (do (assert.are.equal 0 results)
            (assert.are.equal 1 result.code)))))

(fn assert-one-ack-per-control! [parent n]
  (for [ref 1 n]
    (assert.are.equal 1 (accumulate [c 0 _ ev (ipairs parent.seen)]
                          (if (and (= ev.type :control-ack) (= ev.ref ref))
                              (+ c 1) c))
                      (.. "acks for control " ref))))

(describe "rpc presenter (fake parent)"
  (fn []
    (before_each (fn []
                   (test-api.reset!)
                   (register-mock!)
                   (steering.clear-queues!)))

    (it "runs prompt -> turn -> close with ready first and result before exit"
      (fn []
        (let [r (run-child
                  {:mock ["hello there"]
                   :tools []
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.send! :prompt {:text "say hi"})
                             (p.wait-type :turn-complete)
                             (p.send! :close {}))})
              p r.parent]
          (assert.are.equal :ready (. p.seen 1 :type))
          (assert.are.equal :accepted (. (p.ack 1) :status))
          (assert.are.equal :accepted (. (p.ack 2) :status))
          (let [started (p.find #(= $1.type :turn-started))
                complete (p.find #(= $1.type :turn-complete))
                result (p.find #(= $1.type :result))]
            (assert.are.equal 1 started.turn)
            (assert.are.equal 1 complete.turn)
            (assert.are.equal "stop" complete.stop-reason)
            (assert.are.equal "hello there" result.final-text)
            (assert.are.equal "stop" result.stop-reason)
            (assert.are.equal :complete result.context))
          ;; Display events are forwarded; the agent-turn-complete bus event too.
          (assert.is_truthy (p.find #(= $1.type :llm-start)))
          (assert.is_truthy (p.find #(= $1.type :agent-turn-complete)))
          (assert.are.equal :done (. (last-event p) :status))
          (assert-one-ack-per-control! p 2)
          (assert-closed-run! r))))

    (it "returns to ready between turns and keeps one conversation"
      (fn []
        (let [r (run-child
                  {:mock ["first" "second"]
                   :tools []
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.send! :prompt {:text "one"})
                             (p.wait (fn [ev] (and (= ev.type :turn-complete) (= ev.turn 1))))
                             (p.send! :steer {:text "two"})
                             (p.wait (fn [ev] (and (= ev.type :turn-complete) (= ev.turn 2))))
                             (p.send! :close {}))})
              last-call (. r.record (length r.record))]
          (assert.are.same ["one" "two"] (user-texts last-call.context.messages))
          (assert.are.equal "second" (. (r.parent.find #(= $1.type :result)) :final-text))
          (assert-closed-run! r))))

    (it "injects a mid-turn steer through the steering queue"
      (fn []
        (let [log []
              r (run-child
                  {:mock [{:tool-call {:id "c1" :name :slow}} "steered answer"]
                   :tools [(slow-tool :slow 3 log)]
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.send! :prompt {:text "work"})
                             (p.wait-type :tool-call)
                             (p.send! :steer {:text "also check tests"})
                             (p.wait-type :turn-complete)
                             (p.send! :close {}))})
              p r.parent]
          (assert.are.equal :accepted (. (p.ack 2) :status))
          (let [injected (p.find #(= $1.type :steering-injected))]
            (assert.are.equal "also check tests" injected.text)
            ;; The injected event names the steer control it applied.
            (assert.are.equal 2 injected.ref))
          ;; Same turn, same process: the steer reached the second provider call.
          (assert.are.equal 1 (count-type p :turn-started))
          (assert.are.same ["work" "also check tests"]
                           (user-texts (. r.record 2 :context :messages)))
          (assert.are.same [:started :finished] log)
          (assert-closed-run! r))))

    (it "queues a mid-turn follow-up and applies it after the natural stop"
      (fn []
        (let [log []
              r (run-child
                  {:mock [{:tool-call {:id "c1" :name :slow}} "first answer" "follow answer"]
                   :tools [(slow-tool :slow 3 log)]
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.send! :prompt {:text "work"})
                             (p.wait-type :tool-call)
                             (p.send! :follow-up {:text "then summarize"})
                             (p.wait-type :turn-complete)
                             (p.send! :close {}))})
              p r.parent]
          (assert.are.equal :accepted (. (p.ack 2) :status))
          (let [injected (p.find #(= $1.type :follow-up-injected))]
            (assert.are.equal "then summarize" injected.text)
            (assert.are.equal 2 injected.ref))
          (assert.are.same ["work" "then summarize"]
                           (user-texts (. r.record 3 :context :messages)))
          (assert.are.equal "follow answer" (. (p.find #(= $1.type :result)) :final-text))
          (assert-closed-run! r))))

    (it "finalizes mid-run without executing the pending tool call"
      (fn []
        (let [log []
              calls []
              script (fn [req]
                       (table.insert calls (or req.options.tool-choice :auto))
                       (if (= req.options.tool-choice :none)
                           ;; A model may still ask for tools; the loop refuses.
                           (if (= (length calls) 2)
                               {:tool-call {:id "c2" :name :slow}}
                               "final summary")
                           {:tool-call {:id "c1" :name :slow}}))
              r (run-child
                  {:mock script
                   :tools [(slow-tool :slow 3 log)]
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.send! :prompt {:text "work"})
                             ;; The reply with the tool call is appended; no tool has run.
                             (p.wait-type :llm-end)
                             (p.send! :finalize {:note "budget reached: wrap up"})
                             (p.send! :finalize {}))})
              p r.parent]
          (assert.are.same [] log)
          (assert.are.equal :accepted (. (p.ack 2) :status))
          (assert.are.equal :applied (. (p.ack 3) :status))
          (assert.are.same [:auto :none :none] calls)
          (let [turns (icollect [_ ev (ipairs p.seen)]
                        (when (= ev.type :turn-complete) ev))]
            (assert.are.equal 2 (length turns))
            (assert.are.equal "aborted" (. turns 1 :stop-reason))
            (assert.are.equal "stop" (. turns 2 :stop-reason)))
          (let [result (p.find #(= $1.type :result))]
            (assert.are.equal "final summary" result.final-text)
            (assert.are.equal :complete result.context))
          ;; The note is the finalize turn's user message, after the paired call.
          (let [sent (. r.record 2 :context :messages)]
            (assert.are.equal "budget reached: wrap up" (. (user-texts sent) 2))
            (each [_ m (ipairs sent)]
              (assert.is_false (and (= m.role :assistant) (= m.stop-reason :aborted)))))
          (assert-closed-run! r))))

    (it "finalizes from ready with one tool-free turn"
      (fn []
        (let [r (run-child
                  {:mock ["answer" "final"]
                   :tools []
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.send! :prompt {:text "work"})
                             (p.wait-type :turn-complete)
                             (p.send! :finalize {})
                             (p.send! :steer {:text "late"}))})
              p r.parent]
          (assert.are.equal :none (. r.record 2 :tool-choice))
          (assert.are.equal :rejected (. (p.ack 3) :status))
          (assert.are.equal "final" (. (p.find #(= $1.type :result)) :final-text))
          (assert-closed-run! r))))

    (it "carries a first-turn tool fact into the finalize turn without replay"
      (fn []
        (let [log []
              r (run-child
                  {:mock [{:tool-call {:id "c1" :name :fact}} "looked it up" "FINAL"]
                   :tools [(slow-tool :fact 1 log "UNIQUE-FACT-7731")]
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.send! :prompt {:text "find the fact"})
                             (p.wait-type :turn-complete)
                             (p.send! :finalize {:note "report the fact"}))})
              final-call (. r.record 3)]
          (assert.are.equal 3 (length r.record))
          (assert.are.equal :none final-call.tool-choice)
          (assert.is_truthy (string.find (context-text final-call) "UNIQUE-FACT-7731" 1 true))
          ;; No replay: the original prompt appears once, then the note.
          (assert.are.same ["find the fact" "report the fact"]
                           (user-texts final-call.context.messages))
          (assert-closed-run! r))))

    (it "cancels mid-tool and exits cancelled without a result"
      (fn []
        (let [log []
              r (run-child
                  {:mock [{:tool-call {:id "c1" :name :slow}} "never"]
                   :tools [(slow-tool :slow 50 log)]
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.send! :prompt {:text "work"})
                             (p.wait-type :tool-call)
                             (coroutine.yield)
                             (coroutine.yield)
                             (p.send! :cancel {})
                             (p.send! :steer {:text "too late"}))})
              p r.parent]
          (assert.are.same [:started] log)
          (assert.are.equal :accepted (. (p.ack 2) :status))
          (assert.are.equal :rejected (. (p.ack 3) :status))
          (assert.are.equal "aborted" (. (p.find #(= $1.type :turn-complete)) :stop-reason))
          (assert.are.equal :cancelled (. (last-event p) :status))
          (assert.are.equal 1 (length r.record))
          (assert-closed-run! r))))

    (it "cancels from ready"
      (fn []
        (let [r (run-child {:mock [] :tools []
                            :script (fn [p]
                                      (p.wait-type :ready)
                                      (p.send! :cancel {}))})]
          (assert.are.equal :cancelled (. (last-event r.parent) :status))
          (assert-closed-run! r))))

    (it "closes mid-run after the current turn and rejects later input"
      (fn []
        (let [log []
              r (run-child
                  {:mock [{:tool-call {:id "c1" :name :slow}} "done working"]
                   :tools [(slow-tool :slow 3 log)]
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.send! :prompt {:text "work"})
                             (p.wait-type :tool-call)
                             (p.send! :close {})
                             (p.send! :close {})
                             (p.send! :follow-up {:text "more"}))})
              p r.parent]
          (assert.are.same [:accepted :applied :rejected]
                           [(. (p.ack 2) :status) (. (p.ack 3) :status) (. (p.ack 4) :status)])
          (assert.are.same [:started :finished] log)
          (assert.are.equal "done working" (. (p.find #(= $1.type :result)) :final-text))
          (assert-closed-run! r))))

    (it "rejects garbage and illegal controls with acks and keeps running"
      (fn []
        (let [log []
              r (run-child
                  {:mock [{:tool-call {:id "c1" :name :slow}} "ok"]
                   :tools [(slow-tool :slow 3 log)]
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.raw! "not json")
                             (p.raw! (json.encode {:v 1 :seq 1 :type :launch :run RUN}))
                             (set p.sender.seq 1)
                             (p.raw! (json.encode {:v 1 :seq 2 :type :prompt :run RUN}))
                             (set p.sender.seq 2)
                             (p.raw! (json.encode {:v 1 :seq 3 :type :prompt :run "other" :text "x"}))
                             (set p.sender.seq 3)
                             ;; Replayed seq: out of order.
                             (p.raw! (json.encode {:v 1 :seq 2 :type :close :run RUN}))
                             (p.send! :prompt {:text "work"})
                             (p.wait-type :tool-call)
                             (p.send! :prompt {:text "again"})
                             (p.wait-type :turn-complete)
                             (p.send! :close {}))})
              p r.parent
              acks (icollect [_ ev (ipairs p.seen)]
                     (when (= ev.type :control-ack) ev))]
          (assert.are.same [:rejected :rejected :rejected :rejected :rejected
                            :accepted :rejected :accepted]
                           (icollect [_ a (ipairs acks)] a.status))
          (assert.is_nil (. acks 1 :ref))
          (assert.are.equal 1 (. acks 2 :ref))
          (assert.are.equal 2 (. acks 3 :ref))
          (assert.are.equal 3 (. acks 4 :ref))
          (assert.is_nil (. acks 5 :ref))
          (assert.is_truthy (string.find (. acks 7 :reason) "steer" 1 true))
          (assert-closed-run! r))))

    (it "exits failed on a wire version mismatch"
      (fn []
        (let [r (run-child {:mock [] :tools []
                            :script (fn [p]
                                      (p.wait-type :ready)
                                      (p.raw! (json.encode {:v 2 :seq 1 :type :prompt
                                                            :run RUN :text "hi"})))})
              exit (last-event r.parent)]
          (assert.are.equal :failed exit.status)
          (assert.is_truthy (string.find exit.error "version" 1 true))
          (assert.are.equal 0 (count-type r.parent :control-ack))
          (assert-closed-run! r))))

    (it "exits timed-out when the deadline passes mid-turn"
      (fn []
        (let [log []
              r (run-child
                  {:mock [{:tool-call {:id "c1" :name :slow}} "never"]
                   :tools [(slow-tool :slow 500 log)]
                   :deadline 1030
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.send! :prompt {:text "work"}))})
              exit (last-event r.parent)]
          (assert.are.equal :timed-out exit.status)
          (assert.are.same [:started] log)
          (assert-closed-run! r))))

    (it "drops queued input when finalize is accepted, then runs one tool-free turn"
      (fn []
        (let [log []
              r (run-child
                  {:mock [{:tool-call {:id "c1" :name :slow}} "final answer"]
                   :tools [(slow-tool :slow 20 log)]
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.send! :prompt {:text "work"})
                             (p.wait-type :tool-call)
                             (p.send! :steer {:text "also check tests"})
                             (p.send! :follow-up {:text "and then more"})
                             (p.wait-ack 3)
                             (p.send! :finalize {}))})
              p r.parent
              final-call (. r.record 2)]
          (assert.are.equal 2 (length r.record))
          (assert.are.equal :none final-call.tool-choice)
          (assert.is_nil (string.find (context-text final-call) "also check tests" 1 true))
          (assert.is_nil (p.find #(= $1.type :steering-injected)))
          (assert.is_nil (p.find #(= $1.type :error)))
          (let [info (p.find #(and (= $1.type :info)
                                   (string.find (or $1.summary "") "dropped" 1 true)))]
            (assert.are.equal "dropped 2 queued input line(s)" info.summary)
            (assert.are.same [2 3] info.refs))
          (assert.are.same [] (. (steering.queue-snapshot) :steering))
          (assert.are.equal "final answer" (. (p.find #(= $1.type :result)) :final-text))
          (assert-closed-run! r))))

    (it "truncates an oversized final answer so the result line still fits"
      (fn []
        (let [big (string.rep "0123456789abcdef" (* 100 64))
              r (run-child
                  {:mock [big]
                   :tools []
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.send! :prompt {:text "write a lot"})
                             (p.wait-type :turn-complete)
                             (p.send! :close {}))})
              result (r.parent.find #(= $1.type :result))]
          (assert.are.equal (* 100 1024) (length big))
          (assert.is_true result.truncated?)
          (assert.are.equal :complete result.context)
          (assert.is_true (> (length result.final-text) 1024))
          (assert.are.equal (string.sub big 1 (length result.final-text)) result.final-text)
          (assert-closed-run! r))))

    (it "exits even when a cancelled turn throws instead of unwinding"
      (fn []
        (let [log []
              r (run-child
                  {:mock [{:tool-call {:id "c1" :name :slow}} "never"]
                   :tools [(slow-tool :slow 50 log)]
                   ;; Simulate the step raising while the run is already cancelled.
                   :wrap-tick (fn [state base]
                                (fn []
                                  (if (and state.turn state.cancel-requested?)
                                      (do (set state.turn-error "tool blew up")
                                          (set state.turn nil)
                                          (set state.busy? false)
                                          (set state.cancel-requested? false))
                                      (base))))
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.send! :prompt {:text "work"})
                             (p.wait-type :tool-call)
                             (p.send! :cancel {}))})
              exit (last-event r.parent)]
          (assert.are.equal :cancelled exit.status)
          (assert.are.equal "error" (. (r.parent.find #(= $1.type :turn-complete)) :stop-reason))
          (assert-closed-run! r))))

    (it "exits failed when the control file is truncated"
      (fn []
        (let [r (run-child
                  {:mock ["hi"]
                   :tools []
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.send! :prompt {:text "go"})
                             (p.wait-type :turn-complete)
                             (let [f (assert (io.open p.control-path :w))]
                               (f:close)))})
              exit (last-event r.parent)]
          (assert.are.equal :failed exit.status)
          (assert.is_truthy (string.find exit.error "truncated" 1 true))
          (assert-closed-run! r))))

    (it "rejects an oversized control line exactly once"
      (fn []
        (let [r (run-child
                  {:mock []
                   :tools []
                   :script (fn [p]
                             (p.wait-type :ready)
                             (p.raw! (string.rep "x" (* 70 1024)))
                             (p.send! :close {}))})
              acks (icollect [_ ev (ipairs r.parent.seen)]
                     (when (= ev.type :control-ack) ev))]
          (assert.are.same [:rejected :accepted] (icollect [_ a (ipairs acks)] a.status))
          (assert.is_nil (. acks 1 :ref))
          (assert.are.equal 1 (. acks 2 :ref))
          (assert-closed-run! r))))

    (it "tracks a turn the runtime tick starts on its own"
      (fn []
        (let [started {:done? false}
              r (run-child
                  {:mock ["from the idle follow-up"]
                   :tools []
                   :wrap-tick (fn [state base]
                                (fn []
                                  (base)
                                  (when (and (not started.done?) (not state.turn))
                                    (set started.done? true)
                                    (turn-submit.start! state "queued follow-up"
                                                        agent-mod.step))))
                   :script (fn [p]
                             (p.wait-type :turn-complete)
                             (p.send! :close {}))})
              p r.parent]
          (assert.are.equal 1 (. (p.find #(= $1.type :turn-started)) :turn))
          (assert.are.equal "from the idle follow-up"
                            (. (p.find #(= $1.type :result)) :final-text))
          (assert-closed-run! r))))))

