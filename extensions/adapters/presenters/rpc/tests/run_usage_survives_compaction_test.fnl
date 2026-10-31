;; Regression test for #618: the rpc presenter's `turn-complete` and `result`
;; usage survive in-run compaction because they are read from the usage ledger,
;; not sliced from agent.messages.
;; See spec/context/FINDINGS.md (#618).

(local test-api (require :fen.core.extensions.test_api))
(local register-registry (require :fen.core.extensions.register))
(local tool-registry (require :fen.core.extensions.register.tool))
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

(fn usage [input]
  {: input :output 0 :cache-read 0 :cache-write 0 :total-tokens input})

(fn script [req]
  "Summary request -> input 30000; else call `compact` once, then answer."
  (let [first (?. req.messages 1 :content)
        summary? (and (= 1 (length req.messages)) (= (type first) :string)
                      (string.find first "Messages to summarize" 1 true))
        called? (accumulate [found false _ m (ipairs req.messages)]
                  (or found (= m.role :tool-result)))]
    (if summary? {:text "summary" :usage (usage 30000)} called?
        {:text "answer" :usage (usage 10)}
        {:tool-call {:id "c1" :name :compact :args {}} :usage (usage 1000)})))

(fn with-id [msg id]
  (tset msg :__session-entry-id id)
  msg)

(fn seeded []
  (let [big (string.rep "x" 90000)]
    [(with-id (types.user-message big) "m1")
     (with-id (types.assistant-message {:content [(types.text-block big)]})
       "m2")
     (with-id (types.user-message big) "m3")
     (with-id (types.assistant-message {:content [(types.text-block "a4")]})
       "m4")
     (with-id (types.user-message "u5") "m5")
     (with-id (types.assistant-message {:content [(types.text-block "a6")]})
       "m6")]))

(fn compact-tool []
  (accumulate [found nil _ t (ipairs (tool-registry.merged []))]
    (or found (when (= t.name :compact) t))))

(fn make-state [mock-script record]
  (let [state {:opts {}
               :session {:id :s}
               :session-backend {:append-entry (fn [_ entry]
                                                 (let [out {:id "comp-1"}]
                                                   (each [k v (pairs entry)]
                                                     (tset out k v))
                                                   out))}
               :flush (fn [] nil)
               :make-flush (fn [] (fn [] nil))}
        agent (agent-mod.make-agent {:provider-name :mock
                                     :model "mock"
                                     :api-key :test
                                     :tools [(compact-tool)]
                                     :tool-context (fn [] {: state})
                                     :on-event (fn [ev] (events.emit ev))
                                     :get-steering (fn []
                                                     (steering.get-steering))
                                     :get-follow-up (fn []
                                                      (steering.get-follow-up))
                                     :provider-options {: mock-script
                                                        :mock-record record}})]
    (each [_ m (ipairs (seeded))]
      (table.insert agent.messages m))
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
        state (make-state opts.mock record)
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
  (steering.clear-queues!)
  (tset package.loaded :fen.extensions.compact nil)
  (let [api (test-api.make-runtime-api :compact {:name :compact})
        compact (require :fen.extensions.compact)]
    (set api.settings {:extension (fn [] {})})
    (compact.register api)))

(describe "#618 rpc usage after in-run compaction"
          (fn []
            (before_each reset!)
            (after_each (fn []
                          (test-api.reset!)
                          (tset package.loaded :fen.extensions.compact nil)))
            (it "survives in-run compaction"
                (fn []
                  (let [r (run-child {:mock script
                                      :script (fn [p]
                                                (p.wait-type :ready)
                                                (p.send! :prompt
                                                         {:text "go"})
                                                (p.wait-type :turn-complete)
                                                (p.send! :close {}))})
                        p r.parent
                        tc (p.find #(= $1.type :turn-complete))
                        result (p.find #(= $1.type :result))
                        bus (accumulate [n 0 _ ev (ipairs p.seen)]
                              (if (and (= ev.type :llm-end)
                                       ev.usage)
                                  (+ n (or ev.usage.input 0))
                                  n))]
                    (assert r.ok? r.err)
                    (assert.are.equal 31010 bus)
                    (assert.are.equal 31010 (?. tc :usage :input))
                    (assert.are.equal 31010 (?. result :usage :input)))))))
