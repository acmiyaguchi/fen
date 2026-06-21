;; Agent-loop integration tests driven by the deterministic mock provider.
;;
;; These are the *blocking-mode* cases migrated out of
;; `packages/core/tests/agent_test.fnl`. Instead of swapping the whole
;; `fen.core.llm` dispatcher (which a core test must do to avoid depending on an
;; extension), they register the real mock provider and run through the real
;; `llm.complete` dispatcher. Responses come from a `:mock-script`; outbound
;; calls are captured via the `:mock-record` recording hook so we can assert on
;; what the agent sent.
;;
;; The cooperative / transport / cancellation cases stay in agent_test.fnl: they
;; program the dispatcher directly (stream/coop sub-methods, yield counting,
;; cancel-fn) and cannot be expressed as a response-only provider.

(local test-api (require :fen.core.extensions.test_api))
(local llm (require :fen.core.llm))
(local mock (require :fen.extensions.provider_mock.mock_provider))
(local agent-mod (require :fen.core.agent))
(local types (require :fen.core.types))

;; ---- mock registration ------------------------------------------

(fn register-mock! [?name]
  "Register a copy of the mock provider record under ?name (default :mock)."
  (let [p {}]
    (each [k v (pairs mock)] (tset p k v))
    (set p.name (or ?name :mock))
    (llm.register p)))

;; ---- response specs ---------------------------------------------

(fn call [id name ?args] {:id id :name name :args (or ?args {})})
(fn tool-spec [id name ?args] {:tool-call (call id name ?args)})

;; ---- event-taxonomy helpers (mirrors agent_test) ----------------

(fn record-events []
  (let [log []]
    (values log (fn [ev] (table.insert log ev)))))

(fn ui-events [log]
  "UI/event-taxonomy helper. Lifecycle append events are asserted separately."
  (let [out []]
    (each [_ ev (ipairs log)]
      (when (not= ev.type :message-appended)
        (table.insert out ev)))
    out))

(fn event-types [log]
  (let [out []]
    (each [_ ev (ipairs (ui-events log))] (table.insert out ev.type))
    out))

(fn any? [pred xs]
  "True if any element of xs satisfies pred."
  (accumulate [f false _ x (ipairs xs)] (or f (pred x))))

(fn find-by-role [msgs role]
  "Last message in msgs with the given role, or nil."
  (accumulate [found nil _ m (ipairs msgs)]
    (if (= m.role role) m found)))

(fn stub-registry [output]
  [{:name :noop :label "Noop"
    :description "no-op"
    :parameters {:type :object :properties {}}
    :execute (fn [_]
               {:content [(types.text-block output)] :is-error? false})}])

(fn raw-unsafe-count [s]
  (var n 0)
  (for [i 1 (length s)]
    (let [b (string.byte s i)]
      (when (or (and (< b 32) (not (or (= b 9) (= b 10) (= b 13))))
                (= b 127))
        (set n (+ n 1)))))
  n)

;; ----------------------------------------------------------------

(describe "core.agent.step (mock provider)"
  (fn []
    (before_each (fn [] (test-api.reset!) (register-mock!)))

    (it "stops after one turn when the model returns a final text"
      (fn []
        (let [(log on-event) (record-events)
              rec []
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event
                       :provider-options {:mock-script ["hello"] :mock-record rec}})]
          (let [final (agent-mod.step agent "hi")]
            (assert.are.equal "hello" final)
            (assert.are.equal 1 (length rec))
            (assert.are.same [:llm-start :llm-end :assistant-text]
                             (event-types log))))))

    (it "emits thinking rows before final assistant text"
      (fn []
        (let [(log on-event) (record-events)
              rec []
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event
                       :provider-options
                       {:mock-script [{:thinking "step by step" :text "answer"}]
                        :mock-record rec}})]
          (let [final (agent-mod.step agent "think")]
            (assert.are.equal "answer" final)
            (assert.are.same [:llm-start :llm-end :assistant-thinking :assistant-text]
                             (event-types log))
            (let [events (ui-events log)]
              (assert.are.equal "step by step" (. events 3 :text))
              (assert.is_false (. events 3 :final?))
              (assert.is_true (. events 3 :spacer-after?))
              (assert.are.equal "answer" (. events 4 :text))
              (assert.is_true (. events 4 :final?)))))))

    (it "emits thinking rows before tool calls"
      (fn []
        (let [(log on-event) (record-events)
              rec []
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry "tool ran")
                       :on-event on-event
                       :provider-options
                       {:mock-script [{:thinking "need a tool"
                                       :tool-call (call "call-1" :noop)}
                                      "done"]
                        :mock-record rec}})]
          (let [final (agent-mod.step agent "use a tool")]
            (assert.are.equal "done" final)
            (assert.are.same
              [:llm-start :llm-end :assistant-thinking :tool-call :tool-result
               :llm-start :llm-end :assistant-text]
              (event-types log))))))

    (it "executes tool calls then continues until a stop"
      (fn []
        (let [(log on-event) (record-events)
              rec []
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry "tool ran")
                       :on-event on-event
                       :provider-options
                       {:mock-script [(tool-spec "call-1" :noop) "done"]
                        :mock-record rec}})]
          (let [final (agent-mod.step agent "use a tool")]
            (assert.are.equal "done" final)
            (assert.are.equal 2 (length rec))
            (assert.are.same
              [:llm-start :llm-end :tool-call :tool-result
               :llm-start :llm-end :assistant-text]
              (event-types log))))))

    (it "passes optional per-agent tool context into tool execution"
      (fn []
        (let [seen {}
              (_ on-event) (record-events)
              run-state {:busy? true}
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools [{:name :ctx-tool
                                :label "Context Tool"
                                :description "records context"
                                :parameters {:type :object}
                                :execute (fn [_args ctx]
                                           (set seen.agent ctx.agent)
                                           (set seen.state ctx.state)
                                           {:content [(types.text-block "ok")]
                                            :is-error? false})}]
                       :tool-context (fn [_agent] {:state run-state})
                       :on-event on-event
                       :provider-options
                       {:mock-script [(tool-spec "call-1" :ctx-tool) "done"]}})]
          (agent-mod.step agent "go")
          (assert.are.equal agent seen.agent)
          (assert.are.equal run-state seen.state))))

    (it "appends a canonical ToolResultMessage after each tool execution"
      (fn []
        (let [(_ on-event) (record-events)
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry "tool output")
                       :on-event on-event
                       :provider-options
                       {:mock-script [(tool-spec "call-xyz" :noop) "ok"]}})]
          (agent-mod.step agent "go")
          (local tr (find-by-role agent.messages :tool-result))
          (assert.is_table tr)
          (assert.are.equal "call-xyz" tr.tool-call-id)
          (assert.are.equal :noop tr.tool-name)
          (assert.is_false tr.is-error?)
          (assert.are.equal "tool output" (. tr.content 1 :text)))))

    (it "sanitizes poison tool results before they enter later provider context"
      (fn []
        (let [poison (.. "safe" (string.char 0) (string.char 255) "tail")
              (_ on-event) (record-events)
              rec []
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry poison)
                       :on-event on-event
                       :provider-options
                       {:mock-script [(tool-spec "call-poison" :noop) "done"]
                        :mock-record rec}})]
          (assert.are.equal "done" (agent-mod.step agent "go"))
          (let [ctx-msgs (. rec 2 :context :messages)
                tr (find-by-role ctx-msgs :tool-result)]
            (assert.is_table tr)
            (assert.are.equal "call-poison" tr.tool-call-id)
            (let [body (. tr.content 1 :text)]
              (assert.are.equal 0 (raw-unsafe-count body))
              (assert.is_truthy (string.find body "\\x00" 1 true))
              (assert.is_truthy (string.find body "\\xFF" 1 true))
              (assert.is_truthy (string.find body "tool output sanitized" 1 true)))))))

    (it "sanitizes thrown tool error text before storing tool error output"
      (fn []
        (let [(_ on-event) (record-events)
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools [{:name :boom
                                :label "Boom"
                                :description "throws binary-ish text"
                                :parameters {:type :object}
                                :execute (fn [_]
                                           (error (.. "bad" (string.char 0) (string.char 255) "err")))}]
                       :on-event on-event
                       :provider-options
                       {:mock-script [(tool-spec "call-boom" :boom) "done"]}})]
          (assert.are.equal "done" (agent-mod.step agent "go"))
          (local tr (find-by-role agent.messages :tool-result))
          (assert.is_table tr)
          (assert.is_true tr.is-error?)
          (let [body (. tr.content 1 :text)]
            (assert.are.equal 0 (raw-unsafe-count body))
            (assert.is_truthy (string.find body "\\x00" 1 true))
            (assert.is_truthy (string.find body "\\xFF" 1 true))))))

    (it "executes multiple tool calls from one assistant turn before continuing"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry "tool output")
                       :on-event on-event
                       :provider-options
                       {:mock-script [{:text "checking"
                                       :tool-calls [(call "call-1" :noop)
                                                    (call "call-2" :noop)]}
                                      "done"]}})]
          (let [final (agent-mod.step agent "go")]
            (assert.are.equal "done" final)
            (assert.are.same
              [:llm-start :llm-end :assistant-text
               :tool-call :tool-result :tool-call :tool-result
               :llm-start :llm-end :assistant-text]
              (event-types log))
            (assert.are.equal :assistant (. agent.messages 2 :role))
            (assert.are.equal :tool-result (. agent.messages 3 :role))
            (assert.are.equal "call-1" (. agent.messages 3 :tool-call-id))
            (assert.are.equal :tool-result (. agent.messages 4 :role))
            (assert.are.equal "call-2" (. agent.messages 4 :tool-call-id))
            (assert.are.equal :assistant (. agent.messages 5 :role))))))

    (it "rejects same-turn same-file edit calls so the model retries as one batch"
      (fn []
        (let [(log on-event) (record-events)
              executed {:n 0}
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools [{:name :edit
                                :label "Edit"
                                :description "stub edit"
                                :parameters {:type :object}
                                :execute (fn [_]
                                           (set executed.n (+ executed.n 1))
                                           {:content [(types.text-block "edited")]
                                            :is-error? false})}]
                       :on-event on-event
                       :provider-options
                       {:mock-script
                        [{:tool-calls
                          [(call "edit-1" :edit
                                 {:path "same.fnl"
                                  :edits [{:old_string "a" :new_string "b"}]})
                           (call "edit-2" :edit
                                 {:path "same.fnl"
                                  :edits [{:old_string "c" :new_string "d"}]})]}
                         "done"]}})]
          (let [final (agent-mod.step agent "go")]
            (assert.are.equal "done" final)
            (assert.are.equal 0 executed.n)
            (assert.are.same
              [:llm-start :llm-end :tool-call :tool-result :tool-call :tool-result
               :llm-start :llm-end :assistant-text]
              (event-types log))
            (assert.are.equal :tool-result (. agent.messages 3 :role))
            (assert.are.equal "edit-1" (. agent.messages 3 :tool-call-id))
            (assert.is_true (. agent.messages 3 :is-error?))
            (assert.is_truthy
              (string.find (. agent.messages 3 :content 1 :text)
                           "single batched edit" 1 true))
            (assert.are.equal :tool-result (. agent.messages 4 :role))
            (assert.are.equal "edit-2" (. agent.messages 4 :tool-call-id))
            (assert.is_true (. agent.messages 4 :is-error?))))))

    (it "injects steering messages before the next provider call"
      (fn []
        (let [(log on-event) (record-events)
              calls {:n 0}
              rec []
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry "tool output")
                       :on-event on-event
                       :get-steering (fn []
                                       (set calls.n (+ calls.n 1))
                                       (if (= calls.n 2) ["please steer"] []))
                       :provider-options
                       {:mock-script [(tool-spec "call-1" :noop) "done"]
                        :mock-record rec}})]
          (let [final (agent-mod.step agent "go")]
            (assert.are.equal "done" final)
            (assert.are.same
              [:llm-start :llm-end :tool-call :tool-result
               :steering-injected :llm-start :llm-end :assistant-text]
              (event-types log))
            (assert.are.equal :user (. agent.messages 4 :role))
            (assert.are.equal "please steer" (. agent.messages 4 :content))
            (assert.are.equal :assistant (. agent.messages 5 :role))
            (assert.are.equal "please steer"
                              (. rec 2 :context :messages 4 :content))))))

    (it "injects steering queued during a natural stop before exiting"
      (fn []
        (let [(log on-event) (record-events)
              polls {:n 0}
              rec []
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event
                       :get-steering (fn []
                                       (set polls.n (+ polls.n 1))
                                       (if (= polls.n 2) ["midrun steer"] []))
                       :provider-options
                       {:mock-script ["first done" "second done"]
                        :mock-record rec}})]
          (let [final (agent-mod.step agent "go")]
            (assert.are.equal "second done" final)
            (assert.are.same
              [:llm-start :llm-end :assistant-text
               :steering-injected :llm-start :llm-end :assistant-text]
              (event-types log))
            (assert.are.equal :user (. agent.messages 3 :role))
            (assert.are.equal "midrun steer" (. agent.messages 3 :content))
            (assert.are.equal "midrun steer"
                              (. rec 2 :context :messages 3 :content))))))

    (it "prefers queued steering over follow-up after a natural stop"
      (fn []
        (let [(log on-event) (record-events)
              steering-polls {:n 0}
              followup-polls {:n 0}
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event
                       :get-steering (fn []
                                       (set steering-polls.n (+ steering-polls.n 1))
                                       (if (= steering-polls.n 2) ["steer first"] []))
                       :get-follow-up (fn []
                                        (set followup-polls.n (+ followup-polls.n 1))
                                        (if (= followup-polls.n 1) ["follow second"] []))
                       :provider-options
                       {:mock-script ["first done" "second done" "third done"]}})]
          (let [final (agent-mod.step agent "go")]
            (assert.are.equal "third done" final)
            (assert.are.same
              [:llm-start :llm-end :assistant-text
               :steering-injected :llm-start :llm-end :assistant-text
               :follow-up-injected :llm-start :llm-end :assistant-text]
              (event-types log))
            (assert.are.equal "steer first" (. agent.messages 3 :content))
            (assert.are.equal "follow second" (. agent.messages 5 :content))))))

    (it "injects follow-up messages after a natural stop and continues"
      (fn []
        (let [(log on-event) (record-events)
              used {:v false}
              rec []
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event
                       :get-follow-up (fn []
                                        (if used.v
                                            []
                                            (do (set used.v true)
                                                ["next task"])))
                       :provider-options
                       {:mock-script ["first done" "second done"]
                        :mock-record rec}})]
          (let [final (agent-mod.step agent "go")]
            (assert.are.equal "second done" final)
            (assert.are.same
              [:llm-start :llm-end :assistant-text
               :follow-up-injected :llm-start :llm-end :assistant-text]
              (event-types log))
            (assert.are.equal :user (. agent.messages 3 :role))
            (assert.are.equal "next task" (. agent.messages 3 :content))
            (assert.are.equal 2 (length rec))))))

    (it "trips the safety cap when the model never stops"
      (fn []
        (let [(log on-event) (record-events)
              rec []
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event
                       :provider-options
                       {:mock-script (fn [_req] (tool-spec "loop" :noop))
                        :mock-record rec}})]
          (let [final (agent-mod.step agent "loop forever")]
            (assert.is_truthy
              (string.find final "tool%-call loop exceeded safety cap"))
            (assert.is_true (<= (length rec) agent-mod.SAFETY-CAP))
            (assert.is_true (>= (length rec) agent-mod.SAFETY-CAP))
            (assert.is_false (any? #(= $1 :error) (event-types log)))))))

    (it "surfaces an error stop-reason and stops the loop"
      (fn []
        (let [(log on-event) (record-events)
              rec []
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event
                       :provider-options
                       {:mock-script [{:error "boom"}] :mock-record rec}})]
          (let [final (agent-mod.step agent "hi")]
            (assert.are.equal "[error] boom" final)
            (assert.are.equal 1 (length rec))
            (assert.is_true (any? #(= $1 :error) (event-types log)))))))

    (it "records an errored turn in history but excludes it from later provider context"
      (fn []
        (let [(_ on-event) (record-events)
              rec []
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event
                       ;; A sequence script would desync here: the agent excludes
                       ;; the errored assistant from later provider context, so a
                       ;; turn index derived from assistant-message count would
                       ;; replay turn 1. Use the function form with closure state
                       ;; to count actual provider calls instead.
                       :provider-options
                       {:mock-script (let [calls {:n 0}]
                                       (fn [_req]
                                         (set calls.n (+ calls.n 1))
                                         (if (= calls.n 1) {:error "boom"} "recovered")))
                        :mock-record rec}})]
          (assert.are.equal "[error] boom" (agent-mod.step agent "hi"))
          (assert.are.equal "recovered" (agent-mod.step agent "again"))
          (assert.are.equal 2 (length rec))
          ;; The retry turn must not replay the errored assistant message
          ;; (its [error]/partial content poisons provider context).
          (assert.is_false
            (any? (fn [m] (and (= m.role :assistant) (= m.stop-reason :error)))
                  (. rec 2 :context :messages)))
          ;; But it stays in the transcript for session/debug records.
          (assert.is_true
            (any? (fn [m] (and (= m.role :assistant) (= m.stop-reason :error)))
                  agent.messages)))))

    (it "passes the per-agent tools to the provider as canonical Tool[]"
      (fn []
        (let [(_ on-event) (record-events)
              rec []
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools [{:name :custom-tool
                                :label "Custom"
                                :description "marker"
                                :parameters {:type :object}
                                :execute (fn [_]
                                           {:content [(types.text-block "")]
                                            :is-error? false})}]
                       :on-event on-event
                       :provider-options {:mock-script ["ok"] :mock-record rec}})]
          (agent-mod.step agent "go")
          (let [first-call (. rec 1)
                names {}]
            (each [_ d (ipairs first-call.context.tools)]
              ;; Tool descriptors are canonical; should NOT have :execute.
              (assert.is_nil d.execute)
              (tset names (tostring d.name) true))
            (assert.is_true (. names "custom-tool"))
            (assert.is_nil (. names "bash"))))))

    (it "applies convert-to-llm before sending messages to the provider"
      (fn []
        (let [(_ on-event) (record-events)
              rec []
              ;; Drop messages whose role is :note (a custom AgentMessage type).
              convert (fn [msgs]
                        (let [out []]
                          (each [_ m (ipairs msgs)]
                            (when (not= m.role :note)
                              (table.insert out m)))
                          out))
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event
                       :convert-to-llm convert
                       :provider-options {:mock-script ["ok"] :mock-record rec}})]
          (table.insert agent.messages {:role :note :content "internal"})
          (agent-mod.step agent "hi")
          (let [first-call (. rec 1)
                roles {}]
            (each [_ m (ipairs first-call.context.messages)]
              (tset roles m.role true))
            (assert.is_nil (. roles :note))
            (assert.is_true (. roles :user)))
          (assert.is_true (any? (fn [m] (= m.role :note)) agent.messages)))))

    (it "passes the system prompt through context, not as a message"
      (fn []
        (let [(_ on-event) (record-events)
              rec []
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :system "you are a test"
                       :tools (stub-registry "")
                       :on-event on-event
                       :provider-options {:mock-script ["ok"] :mock-record rec}})]
          (agent-mod.step agent "hi")
          (let [first-call (. rec 1)]
            (assert.are.equal "you are a test" first-call.context.system-prompt)
            ;; agent.messages should NOT contain a :system-role entry.
            (assert.is_false (any? (fn [m] (= m.role :system)) agent.messages))))))

    (it "dispatches by :provider-name"
      (fn []
        ;; Register the mock under a distinct name and point the agent at it.
        ;; Only this name is registered, so a successful, recorded call proves
        ;; the agent dispatched through provider-name (a wrong name would make
        ;; llm.complete raise "unknown provider").
        (test-api.reset!)
        (register-mock! :anthropic)
        (let [(_ on-event) (record-events)
              rec []
              agent (agent-mod.make-agent
                      {:provider-name :anthropic
                       :model "mock" :api-key :test
                       :tools (stub-registry "")
                       :on-event on-event
                       :provider-options {:mock-script ["ok"] :mock-record rec}})]
          (assert.are.equal "ok" (agent-mod.step agent "hi"))
          (assert.are.equal 1 (length rec)))))

    (it "emits :message-appended after each message append"
      (fn []
        (let [(log on-event) (record-events)
              agent (agent-mod.make-agent
                      {:provider-name :mock
                       :model "mock" :api-key :test
                       :tools (stub-registry "tool output")
                       :on-event on-event
                       :provider-options
                       {:mock-script [(tool-spec "call-1" :noop) "done"]}})]
          (agent-mod.step agent "go")
          (let [roles [] indexes []]
            (each [_ ev (ipairs log)]
              (when (= ev.type :message-appended)
                (table.insert roles ev.message.role)
                (table.insert indexes ev.index)
                (assert.are.equal agent ev.agent)))
            (assert.are.same [:user :assistant :tool-result :assistant] roles)
            (assert.are.same [1 2 3 4] indexes)))))

    ))
