;; Regression for #664 (parent half): a steer that arrives once `close` is sent
;; or the child has exited is rejected up front or reported dropped at settle,
;; never sent after close and silently lost.

(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local tools (require :fen.core.tools))
(local wire (require :fen.util.wire))

;; ---- fake child (as in init_test.fnl) ----

(local clock {:now 1000})
(var children [])

(fn append-line! [p line]
  (let [f (assert (io.open p :a))]
    (f:write line "\n")
    (f:close)))

(fn fake-child [opts script]
  "A child process stand-in: SCRIPT runs as a coroutine resumed once per
   handle tick, after the controls appended so far have been read."
  (let [env opts.env
        child {:argv opts.argv
               :env env
               :controls []
               :next-index 1
               :reader (wire.line-reader env.FEN_WIRE_CONTROL_PATH)
               :receiver (wire.receiver :control)
               :sender (wire.sender :event env.FEN_WIRE_RUN_ID)
               :aborted? false
               :code nil}]
    (fn child.emit! [typ ?payload]
      (let [(line rej) (wire.next! child.sender typ ?payload)]
        (assert line (tostring (?. rej :reason)))
        (append-line! env.FEN_WIRE_EVENT_PATH line)))

    (fn child.read! []
      (let [(lines) (wire.read-lines! child.reader)]
        (each [_ line (ipairs lines)]
          (when (not= line "")
            (let [(msg rej) (wire.receive! child.receiver line)]
              (assert msg (tostring (?. rej :reason)))
              (table.insert child.controls msg))))))

    (fn child.next! []
      (while (not (. child.controls child.next-index))
        (coroutine.yield))
      (let [msg (. child.controls child.next-index)]
        (set child.next-index (+ child.next-index 1))
        msg))

    (fn child.expect! [typ ?status]
      (let [msg (child.next!)]
        (assert (= msg.type typ) (.. "expected " typ " control, got " msg.type))
        (child.emit! :control-ack {:ref msg.seq :status (or ?status :accepted)})
        msg))

    (fn child.types []
      (icollect [_ c (ipairs child.controls)] c.type))

    (fn child.exit! [status]
      (child.emit! :exit {: status})
      (set child.code (if (= status :done) 0 1)))

    (let [co (coroutine.create (fn [] (script child)))]
      (set child.handle
           {:abort (fn [_] (set child.aborted? true))
            :resume (fn [_]
                      (if child.aborted?
                          (values true
                                  {:exit-code nil
                                   :signal 9
                                   :cancelled? true
                                   :duration-ms 7
                                   :output "killed"})
                          child.code
                          (values true
                                  {:exit-code child.code
                                   :duration-ms 7
                                   :output "child output"})
                          (do
                            (child.read!)
                            (when (= (coroutine.status co) :suspended)
                              (let [(ok? err) (coroutine.resume co)]
                                (assert ok? err)))
                            (when (and (= (coroutine.status co) :dead)
                                       (not child.code))
                              (set child.code 3))
                            (values false nil))))}))
    child))

(fn start! [child]
  (child.emit! :agent-started {:provider "mock" :model "mock"})
  (child.emit! :ready {}))

(fn prompt! [child]
  (child.expect! :prompt)
  (child.emit! :turn-started {:turn 1}))

(fn answer! [child text ?turn]
  (child.emit! :assistant-text {: text :final? true})
  (child.emit! :llm-end {:usage {:input 1 :output 1 :total-tokens 2}})
  (child.emit! :turn-complete {:turn (or ?turn 1) :stop-reason "stop"}))

(fn result! [child text]
  (child.emit! :result
               {:final-text text
                :stop-reason "stop"
                :usage {:input 1 :output 1 :total-tokens 2}})
  (child.exit! :done))

(local MOCKED [:fen.util.process
               :fen.util.clock
               :fen.runtime
               :fen.extensions.subagent.discover])

(local scout-cfg {:name "scout"
                  :description "Recon"
                  :model "claude-haiku-4-5"
                  :tools ["read" "grep" "find" "ls"]
                  :body "You are a scout."})

(fn install-mocks [script]
  (set children [])
  (set clock.now 1000)
  (tset package.loaded :fen.util.process
        {:start-captured (fn [opts]
                           (let [child (fake-child opts script)]
                             (table.insert children child)
                             child.handle))})
  (tset package.loaded :fen.util.clock
        {:monotonic-ms (fn [] clock.now)
         :sleep-ms (fn [ms] (set clock.now (+ clock.now ms)))})
  (tset package.loaded :fen.runtime {:binary-path (fn [] "/bin/true")})
  (tset package.loaded :fen.extensions.subagent.discover
        {:find-agent (fn [name] (when (= name :scout) scout-cfg))
         :list (fn [] [])
         :roots (fn [] [])}))

(fn reset-modules! []
  (each [_ m (ipairs [:fen.extensions.subagent
                      :fen.extensions.subagent.runs
                      :fen.extensions.subagent.channel
                      :fen.extensions.subagent.state])]
    (tset package.loaded m nil)))

(fn fresh []
  (test-api.reset!)
  (reset-modules!)
  (let [subagent (require :fen.extensions.subagent)]
    (subagent.register (test-api.make-runtime-api :subagent))))

(fn runs [] (require :fen.extensions.subagent.runs))

(fn snapshot []
  ((. (runs) :snapshot)))

(fn execute-tool [args]
  (let [out (tools.execute-call (tool-registry.merged [])
                                {:type :tool-call
                                 :id "call-1"
                                 :name :subagent
                                 :arguments args}
                                {})]
    out.result))

(fn first-text [content]
  (let [b (. content 1)]
    (if (and b (= b.type :text)) b.text "")))

(fn event-types [run]
  (icollect [_ ev (ipairs (or run.events []))]
    ev.type))

(fn has-event? [run typ]
  (accumulate [found? false _ ev (ipairs (or run.events [])) &until found?]
    (= ev.type typ)))

(fn with-mocks [f]
  "Run F with the process, clock, runtime, and discovery mocks installed;
   restore the real modules afterwards."
  (let [saved (collect [_ m (ipairs MOCKED)] m (. package.loaded m))
        steering (require :fen.extensions.steering.service)]
    (steering.clear-queues!)
    (let [(ok? v) (pcall f)]
      (each [_ m (ipairs MOCKED)]
        (tset package.loaded m (. saved m)))
      (reset-modules!)
      (steering.clear-queues!)
      (assert ok? v)
      v)))

(describe "subagent parent: a steer after close (#664)"
          (fn []
            (it "is held after close is sent and reported dropped"
                (fn []
                  (with-mocks (fn []
                                (install-mocks (fn [child]
                                                 (start! child)
                                                 (prompt! child)
                                                 (answer! child "answer")
                                                 (child.expect! :close)
                                                 (let [(run why) ((. (runs)
                                                                     :request-steer!) "subagent-1"
                                                                                      "too late"
                                                                                      :agent)]
                                                   (set child.steer-why why))
                                                 (coroutine.yield)
                                                 (result! child "answer")))
                                (fresh)
                                (let [r (execute-tool {:agent :scout
                                                       :task "look"})
                                      child (. children 1)]
                                  (assert (not r.is-error?))
                                  (assert (= "prompt,close"
                                             (table.concat (child.types) ",")))
                                  (assert (= :closing child.steer-why)))))))
            (it "is reported dropped when it is queued but never sent"
                (fn []
                  (with-mocks (fn []
                                (install-mocks (fn [child]
                                                 (start! child)
                                                 (prompt! child)
                                                 (answer! child "answer")
                                                 ;; the user's request lands before close was sent
                                                 (assert ((. (runs)
                                                             :request-steer!) "subagent-1"
                                                                              "before close"
                                                                              :agent))
                                                 (result! child "answer")))
                                (fresh)
                                (let [r (execute-tool {:agent :scout
                                                       :task "look"})
                                      run (. (snapshot) :runs 1)]
                                  (assert (not r.is-error?))
                                  (assert (= :completed run.status))
                                  (assert (has-event? run :steering-dropped)))))))))
