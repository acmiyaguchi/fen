;; Known bug #649 (spec/subagents, `budgetEnforced`): `maybe-finalize!`
;; sends `finalize` only while `final-answer-produced?` is unset, and that
;; flag is set at the child's first final answer and never cleared. A steer
;; injected at that natural stop resumes the run, and no budget applies any
;; more. The same scripted work runs twice with `max-tool-calls 2`: once
;; plainly (the control: finalize is sent), once steered after an answer.

(local {: known-bug} (require :fen.testing))
(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local wire (require :fen.util.wire))

;; ---- fake child (copied from init_test.fnl's conformance kit) ----

(local clock {:now 1000})
(var children [])

(fn append-line! [p line]
  (let [f (assert (io.open p :a))]
    (f:write line "\n")
    (f:close)))

(fn fake-child [opts script]
  "A child process stand-in: SCRIPT runs as a coroutine resumed once per
   handle tick, reading controls and writing wire events. `abort` is a kill."
  (let [env opts.env
        child {:argv opts.argv
               :env env
               :opts opts
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

    (fn child.expect! [typ ?status ?reason]
      (let [msg (child.next!)]
        (assert (= msg.type typ) (.. "expected " typ " control, got " msg.type))
        (child.emit! :control-ack
                     {:ref msg.seq
                      :status (or ?status :accepted)
                      :reason ?reason})
        msg))

    (fn child.types []
      (icollect [_ c (ipairs child.controls)] c.type))

    (fn child.exit! [status ?code]
      (child.emit! :exit {: status})
      (set child.code (or ?code (if (= status :done) 0 1))))

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
  (let [p (child.expect! :prompt)]
    (set child.prompt p.text)
    (child.emit! :turn-started {:turn 1})
    p))

(fn answer! [child text]
  (child.emit! :assistant-text {: text :final? true})
  (child.emit! :llm-end {:usage {:input 1 :output 1 :total-tokens 2}})
  (child.emit! :turn-complete {:turn 1 :stop-reason "stop"}))

(fn result! [child text]
  (child.emit! :result
               {:final-text text
                :stop-reason "stop"
                :usage {:input 1 :output 1 :total-tokens 2}})
  (child.exit! :done))

(fn close! [child text]
  (child.expect! :close)
  (result! child text))

(fn simple [text]
  (fn [child]
    (start! child)
    (prompt! child)
    (answer! child text)
    (close! child text)))

(local STUBBED [:fen.util.process
                :fen.util.clock
                :fen.runtime
                :fen.extensions.subagent.discover])

(fn install-mocks [script find-agent-fn]
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
        {:find-agent find-agent-fn :list (fn [] []) :roots (fn [] [])}))

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
    (subagent.register (test-api.make-runtime-api :subagent))
    subagent))

(fn runs [] (require :fen.extensions.subagent.runs))

(fn snapshot []
  ((. (runs) :snapshot)))

(fn registered-tool [name]
  (accumulate [found nil _ rec (ipairs (tool-registry.merged [])) &until found]
    (when (= rec.name name) rec)))

(fn argv-value [argv flag]
  (accumulate [found nil i item (ipairs (or argv [])) &until found]
    (when (= item flag) (. argv (+ i 1)))))

(fn remove-child-files! []
  "Remove every temp file a fake child's run was given (system prompt,
   control, event), whether or not the run settled."
  (each [_ child (ipairs children)]
    (each [_ p (ipairs [(argv-value child.argv "--system-file")
                        child.env.FEN_WIRE_CONTROL_PATH
                        child.env.FEN_WIRE_EVENT_PATH])]
      (when p (os.remove p)))
    (wire.close-reader! child.reader)))

(fn with-stubs [body]
  "Snapshot the stubbed modules, run BODY, then restore them and remove the
   run's temp files even when BODY fails."
  (let [saved (collect [_ m (ipairs STUBBED)] m (. package.loaded m))
        (ok? err) (pcall body)]
    (remove-child-files!)
    (each [_ m (ipairs STUBBED)]
      (tset package.loaded m (. saved m)))
    (reset-modules!)
    ((. (require :fen.extensions.steering.service) :clear-queues!))
    (when (not ok?) (error err 0))))

(fn tool-calls! [child n]
  "N tool calls, yielding after each so the parent pumps in between."
  (for [i 1 n]
    (child.emit! :tool-call {:name "read" :arguments {:path (.. "f" i)}})
    (coroutine.yield)
    (coroutine.yield)))

(fn control-run [child]
  (start! child)
  (prompt! child)
  (tool-calls! child 2)
  (child.expect! :finalize)
  (child.emit! :turn-complete {:turn 1 :stop-reason "aborted"})
  (child.emit! :turn-started {:turn 2})
  (answer! child "findings")
  (result! child "findings"))

(fn steered-run [child]
  (start! child)
  (prompt! child)
  ;; A final answer at a natural stop, then a steer injected there resumes work.
  (child.emit! :assistant-text {:text "first answer" :final? true})
  ((. (runs) :request-steer!) "subagent-1" "dig deeper" :agent)
  (let [steer (child.expect! :steer)]
    (child.emit! :steering-injected {:text steer.text :ref steer.seq}))
  (tool-calls! child 6)
  (answer! child "deeper findings")
  (close! child "deeper findings"))

(fn launch [script]
  (install-mocks script (fn [_] {:name "a" :body "b"}))
  (fresh)
  (let [tool (registered-tool :subagent)
        r (tool.execute {:agent :a :task "review" :max-tool-calls 2} {})]
    {:types ((. children 1 :types))
     :count r.details.tool-call-count
     :requested? r.details.budget-finalization-requested?}))

(describe "subagent known bug #649"
          (fn []
            (it "sends no finalize for a spent budget once a steer resumed an answered run"
                (fn []
                  (known-bug 649
                             (fn []
                               (var unenforced? false)
                               (with-stubs (fn []
                                             (let [ctl (launch control-run)]
                                               ;; the budget works without the steer
                                               (assert (= :finalize
                                                          (. ctl.types 2)))
                                               (assert ctl.requested?))
                                             (remove-child-files!)
                                             (let [st (launch steered-run)]
                                               (set unenforced?
                                                    (and (> st.count 2)
                                                         (not st.requested?)
                                                         (= (table.concat st.types
                                                                          ",")
                                                            "prompt,steer,close"))))))
                               unenforced?))))))
