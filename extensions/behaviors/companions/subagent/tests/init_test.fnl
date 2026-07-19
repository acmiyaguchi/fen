(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local command-registry (require :fen.core.extensions.register.command))
(local prompt-registry (require :fen.core.extensions.register.prompt))
(local register-registry (require :fen.core.extensions.register))
(local tools (require :fen.core.tools))
(local json (require :fen.util.json))
(local events (require :fen.core.extensions.events))
(local subagent-events (require :fen.extensions.subagent.events))

;; Mocks for the child-spawning collaborators. The process mock writes a blob
;; to the FEN_JSON_OUTPUT_PATH the tool passes via :env, then returns a result
;; record shaped like run-captured's.
(fn install-mocks [run-captured-fn find-agent-fn ?list-fn ?roots-fn ?start-captured-fn]
  (tset package.loaded :fen.util.process
        {:run-captured run-captured-fn
         :start-captured ?start-captured-fn
         :monotonic-ms (fn [] 1000)
         :sleep-ms (fn [_ms])})
  (tset package.loaded :fen.runtime {:binary-path (fn [] "/bin/true")})
  (tset package.loaded :fen.extensions.subagent.discover
        {:find-agent find-agent-fn
         :list (or ?list-fn (fn [] []))
         :roots (or ?roots-fn (fn [] []))}))

(fn fresh []
  (test-api.reset!)
  (tset package.loaded :fen.extensions.subagent nil)
  (tset package.loaded :fen.extensions.subagent.state nil)
  (let [subagent (require :fen.extensions.subagent)
        api (test-api.make-runtime-api :subagent)]
    (subagent.register api)
    subagent))

(fn fresh-captured []
  (tset package.loaded :fen.extensions.subagent nil)
  (tset package.loaded :fen.extensions.subagent.state nil)
  (let [api (test-api.make :subagent)
        subagent (require :fen.extensions.subagent)]
    (subagent.register api)
    api))

(fn registered-tool [name]
  (var found nil)
  (each [_ rec (ipairs (tool-registry.merged []))]
    (when (and (= found nil) (= rec.name name))
      (set found rec)))
  found)

(fn tool-registered? [name]
  (not (not (registered-tool name))))

(fn registered-command? [name]
  (var found? false)
  (each [_ rec (ipairs (command-registry.list))]
    (when (= rec.name name)
      (set found? true)))
  found?)

(fn registered? [kind name]
  (var found? false)
  (each [_ rec (ipairs (register-registry.list kind))]
    (when (= rec.name name)
      (set found? true)))
  found?)

(fn status-spec []
  (var found nil)
  (each [_ rec (ipairs (register-registry.list :status))]
    (when (= rec.name :subagent)
      (set found rec)))
  found)

(fn snapshot []
  (. (register-registry.collect-introspection :subagent nil) :subagent :state))

(fn captured-command-spec [api name]
  (var found nil)
  (each [_ rec (ipairs api.captured.commands)]
    (when (and (= found nil) (= (. rec.spec :name) name))
      (set found rec.spec)))
  found)

(fn last-assistant-text [api]
  (var text nil)
  (each [_ ev (ipairs api.captured.events-out)]
    (when (= ev.type :assistant-text)
      (set text ev.text)))
  text)

(fn execute-tool [args ?ctx]
  (let [reg (tool-registry.merged [])
        out (tools.execute-call reg
                                {:type :tool-call :id "call-1"
                                 :name :subagent :arguments args}
                                (or ?ctx {}))]
    out.result))

(fn argv-has? [argv flag val]
  (var found? false)
  (each [i item (ipairs (or argv []))]
    (when (and (= item flag) (= (. argv (+ i 1)) val))
      (set found? true)))
  found?)

(fn argv-flag? [argv flag]
  (var found? false)
  (each [_ item (ipairs (or argv []))]
    (when (= item flag) (set found? true)))
  found?)

(fn first-text [content]
  (let [b (. content 1)]
    (if (and b (= b.type :text)) b.text "")))

(local scout-cfg {:name "scout" :description "Recon"
                  :model "claude-haiku-4-5" :provider nil
                  :timeout-seconds nil :body "You are a scout."})

(describe "subagent tool"
  (fn []
    (var saved {})
    (before_each
      (fn []
        (set saved {:process (. package.loaded :fen.util.process)
                    :runtime (. package.loaded :fen.runtime)
                    :discover (. package.loaded :fen.extensions.subagent.discover)
                    :subagent (. package.loaded :fen.extensions.subagent)
                    :subagent-state (. package.loaded :fen.extensions.subagent.state)})))
    (after_each
      (fn []
        (tset package.loaded :fen.util.process saved.process)
        (tset package.loaded :fen.runtime saved.runtime)
        (tset package.loaded :fen.extensions.subagent.discover saved.discover)
        (tset package.loaded :fen.extensions.subagent saved.subagent)
        (tset package.loaded :fen.extensions.subagent.state saved.subagent-state)))

    (it "registers the subagent tool"
      (fn []
        (fresh)
        (assert.is_true (tool-registered? :subagent))))

    (it "marks subagent parallel-safe with cap 4"
      (fn []
        (fresh)
        (let [tool (registered-tool :subagent)]
          (assert.is_truthy tool)
          (assert.is_true (. tool :parallel-safe?))
          (assert.are.equal 4 (. tool :parallel-cap)))))

    (it "registers the subagent run command, status, and introspection"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] nil))
        (fresh)
        (assert.is_true (registered-command? :subagents))
        (assert.is_true (registered? :status :subagent))
        (assert.is_true (registered? :introspectors :state))
        (let [snap (snapshot)]
          (assert.are.equal 0 snap.active-count)
          (assert.are.equal 0 (length snap.runs)))))

    (it "registers the agents command with name completions"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] nil)
          (fn [] [{:key "scout" :name "Scout Agent" :description "Recon" :scope :project}
                  {:key "planner" :name "Planner Agent" :description "Plan work" :scope :user}]))
        (fresh)
        (assert.is_true (registered-command? :agents))
        (let [choices (command-registry.arg-completions :agents "" {})
              seen-values {}]
          (each [_ c (ipairs choices)]
            (tset seen-values c.value true))
          (assert.is_true (. seen-values :scout))
          (assert.is_true (. seen-values :planner)))))

    (it "prints a clear empty agents listing with searched roots"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] nil)
          (fn [] [])
          (fn [] [{:path "./.fen/agents" :scope :project}
                  {:path "/home/me/.config/fen/agents" :scope :user}]))
        (let [api (fresh-captured)
              cmd (captured-command-spec api :agents)]
          (assert.is_truthy cmd)
          (cmd.handler "" {})
          (let [out (last-assistant-text api)]
            (assert.is_truthy (string.find out "No subagents discovered" 1 true))
            (assert.is_truthy (string.find out "Searched roots" 1 true))
            (assert.is_truthy (string.find out "project: ./.fen/agents" 1 true))
            (assert.is_truthy (string.find out "user: /home/me/.config/fen/agents" 1 true))))))

    (it "prints discovered project and user agents with metadata"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] nil)
          (fn [] [{:name "planner" :description "Plan work" :scope :user}
                  {:name "scout" :description "Recon" :scope :project
                   :provider "anthropic" :model "haiku" :timeout-seconds 45}])
          (fn [] []))
        (let [api (fresh-captured)
              cmd (captured-command-spec api :agents)]
          (cmd.handler "" {})
          (let [out (last-assistant-text api)]
            (assert.is_truthy (string.find out "planner" 1 true))
            (assert.is_truthy (string.find out "user" 1 true))
            (assert.is_truthy (string.find out "inherit" 1 true))
            (assert.is_truthy (string.find out "300s default" 1 true))
            (assert.is_truthy (string.find out "scout" 1 true))
            (assert.is_truthy (string.find out "project" 1 true))
            (assert.is_truthy (string.find out "anthropic/haiku" 1 true))
            (assert.is_truthy (string.find out "45s" 1 true))
            (assert.is_truthy (string.find out "Recon" 1 true))))))

    (it "renders a compact subagents prompt only with stable names and descriptions"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] nil)
          (fn [] [{:name "scout" :description "Recon" :scope :project
                   :provider "anthropic" :model "haiku" :timeout-seconds 45}]))
        (fresh)
        (let [rendered (prompt-registry.render {:tools [{:name :subagent}]})]
          (assert.is_truthy (string.find rendered "Available subagents" 1 true))
          (assert.is_truthy (string.find rendered "scout: Recon" 1 true))
          (assert.is_nil (string.find rendered "project" 1 true))
          (assert.is_nil (string.find rendered "anthropic" 1 true))
          (assert.is_nil (string.find rendered "45s" 1 true)))))

    (it "omits the subagents prompt when the subagent tool is not visible"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] nil)
          (fn [] [{:key "scout" :name "Scout Agent" :description "Recon" :scope :project}]))
        (fresh)
        (assert.is_nil (prompt-registry.render {:tools []}))))

    (it "omits the subagents prompt when no agents exist"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] nil)
          (fn [] []))
        (fresh)
        (assert.is_nil (prompt-registry.render {:tools [{:name :subagent}]}))))

    (it "caps the subagents prompt fragment"
      (fn []
        (let [agents []]
          (for [i 1 10]
            (table.insert agents {:key (.. "agent" i)
                                  :name (.. "Agent " i)
                                  :description (string.rep "x" 140)
                                  :scope :project}))
          (install-mocks
            (fn [_opts _yield] (error "should not spawn"))
            (fn [_name] nil)
            (fn [] agents))
          (fresh)
          (let [rendered (prompt-registry.render {:tools [{:name :subagent}]})]
            (assert.is_truthy (string.find rendered "agent1" 1 true))
            (assert.is_nil (string.find rendered "agent9" 1 true))
            (assert.is_truthy (string.find rendered "2 more" 1 true))))))

    (it "returns the child's final text and usage on success"
      (fn []
        (var seen-argv nil)
        (install-mocks
          (fn [opts _yield]
            ;; Validate the spawn shape and write the result blob the tool
            ;; expects to decode back.
            (set seen-argv opts.argv)
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "found it"
                                     :usage {:input 10 :output 4 :total-tokens 14}
                                     :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 12 :output "ignored"})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "find the thing"})]
          (assert.is_false r.is-error?)
          (assert.are.equal "found it" (first-text r.content))
          (assert.are.equal 14 (. r.details :usage :total-tokens))
          (assert.are.equal "stop" (. r.details :stop-reason))
          (assert.are.equal 0 (. r.details :exit-code))
          ;; argv carries the json presenter, the task, a system file, and the
          ;; model override; never a shell string.
          (assert.is_truthy seen-argv)
          (let [joined (table.concat seen-argv " ")]
            (assert.is_truthy (string.find joined "--presenter json" 1 true))
            (assert.is_truthy (string.find joined "find the thing" 1 true))
            (assert.is_truthy (string.find joined "--system-file" 1 true))
            (assert.is_truthy (string.find joined "--model claude-haiku-4-5" 1 true)))
          (assert.are.equal "subagent-1" (. r.details :run-id)))))

    (it "runs an inline prompt without a discovered agent doc"
      (fn []
        (var seen-argv nil)
        (install-mocks
          (fn [opts _yield]
            (set seen-argv opts.argv)
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "inline result"
                                     :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 5 :output ""})
          ;; find-agent must never be consulted for an inline prompt.
          (fn [_name] (error "should not look up an agent")))
        (fresh)
        (let [r (execute-tool {:prompt "You are a one-off helper."
                               :task "say hi"
                               :model "claude-haiku-4-5"
                               :provider "anthropic"})]
          (assert.is_false r.is-error?)
          (assert.are.equal "inline result" (first-text r.content))
          (assert.are.equal "inline" (. r.details :agent))
          (assert.is_truthy seen-argv)
          (let [joined (table.concat seen-argv " ")]
            (assert.is_truthy (string.find joined "--system-file" 1 true))
            (assert.is_truthy (string.find joined "--model claude-haiku-4-5" 1 true))
            (assert.is_truthy (string.find joined "--provider anthropic" 1 true))))))

    (it "errors when neither agent nor prompt is supplied"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] nil))
        (fresh)
        (let [r (execute-tool {:task "do something"})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "agent" 1 true))
          (assert.is_truthy (string.find (first-text r.content) "prompt" 1 true)))))

    (it "prefers a named agent over an inline prompt when both are given"
      (fn []
        (var looked-up nil)
        (install-mocks
          (fn [opts _yield]
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "agent result" :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 5 :output ""})
          (fn [name] (set looked-up name) (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout
                               :prompt "inline body that should be ignored"
                               :task "find the thing"})]
          (assert.is_false r.is-error?)
          (assert.are.equal :scout looked-up)
          (assert.are.equal :scout (. r.details :agent)))))

    (it "tracks active and recent subagent runs"
      (fn []
        (var status-during nil)
        (var command-during nil)
        (var active-api nil)
        (install-mocks
          (fn [opts _yield]
            (set status-during ((. (status-spec) :render) {}))
            (command-registry.dispatch "/subagents" {:busy? true})
            (set command-during (last-assistant-text active-api))
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "done" :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 42 :output ""})
          (fn [name] (when (= name :scout) scout-cfg)))
        (let [api (fresh-captured)
              tool (registered-tool :subagent)]
          (set active-api api)
          (let [r (tool.execute {:agent :scout :task "inspect active state"}
                                {:api api})]
          (assert.is_false r.is-error?)
          (assert.are.equal "subagent:1 running" status-during.text)
          (assert.is_truthy (string.find command-during "subagent-1" 1 true))
          (assert.is_truthy (string.find command-during "running" 1 true))
          (assert.is_nil ((. (status-spec) :render) {}))
          (let [snap (snapshot)]
            (assert.are.equal 0 snap.active-count)
            (assert.are.equal 1 (length snap.runs))
              (assert.are.equal :completed (. snap.runs 1 :status))
              (assert.are.equal 42 (. snap.runs 1 :duration-ms)))))))

    (it "drains live child events into run state"
      (fn []
        (var seen-env nil)
        (install-mocks
          (fn [opts yield]
            (set seen-env opts.env)
            (let [event-path (. opts.env :FEN_SUBAGENT_EVENT_PATH)
                  ef (assert (io.open event-path :a))]
              (ef:write (json.encode {:type :tool-call
                                      :name :grep
                                      :summary "search files"}))
              (ef:write "\n")
              (ef:close))
            (when yield (yield))
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "done" :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 42 :output ""})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "inspect live events"})
              snap (snapshot)
              run (. snap.runs 1)]
          (assert.is_false r.is-error?)
          (assert.is_truthy (. r.details :event-count))
          (assert.is_true (>= (. r.details :event-count) 2))
          (assert.are.equal "subagent-1" (. seen-env :FEN_SUBAGENT_RUN_ID))
          (assert.is_true (>= run.event-count 2))
          (assert.are.equal :subagent-start (. run.events 1 :type))
          (assert.are.equal :tool-call (. run.events 2 :type))
          (assert.are.equal "search files" (. run.events 2 :summary)))))

    (it "keeps long-running active runs visible past the recent history window"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] nil))
        (let [api (fresh-captured)
              run-state (require :fen.extensions.subagent.state)
              active (run-state.start! {:agent :scout :task "long running"
                                        :requested-cwd "/tmp" :cwd "/tmp"
                                        :physical-cwd "/tmp"})]
          (for [i 1 25]
            (let [r (run-state.start! {:agent :scout
                                       :task (.. "finished " i)
                                       :requested-cwd "/tmp" :cwd "/tmp"
                                       :physical-cwd "/tmp"})]
              (run-state.finish! r.id :completed {:duration-ms i})))
          (let [snap (snapshot)]
            (assert.are.equal 1 snap.active-count)
            (assert.are.equal active.id (. snap.active-runs 1 :id))
            (var active-in-runs? false)
            (each [_ r (ipairs snap.runs)]
              (when (= r.id active.id)
                (set active-in-runs? true)))
            (assert.is_true active-in-runs?))
          (command-registry.dispatch "/subagents" {:busy? true})
          (let [out (last-assistant-text api)]
            (assert.is_truthy (string.find out active.id 1 true))
            (assert.is_truthy (string.find out "running" 1 true))))))

    (it "lets /subagents cancel request current-turn cancellation"
      (fn []
        (var cancelled? false)
        (install-mocks
          (fn [opts _yield]
            (let [run-state {:busy? true :cancel-requested? false}]
              (command-registry.dispatch "/subagents cancel" run-state)
              (set cancelled? run-state.cancel-requested?))
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "still returned" :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 10 :output ""})
          (fn [name] (when (= name :scout) scout-cfg)))
        (let [api (fresh-captured)
              tool (registered-tool :subagent)
              r (tool.execute {:agent :scout :task "cancel me"} {:api api})
              out (last-assistant-text api)]
          (assert.is_false r.is-error?)
          (assert.is_true cancelled?)
          (assert.is_truthy (string.find out "Requested cancellation" 1 true)))))

    (it "queues steering notes and restarts the child"
      (fn []
        (var attempts 0)
        (var restarted-argv nil)
        (install-mocks
          (fn [opts yield]
            (set attempts (+ attempts 1))
            (if (= attempts 1)
                (do
                  (command-registry.dispatch "/subagents steer subagent-1 focus on cwd" {:busy? true})
                  (when yield (yield))
                  (error "expected steering yield to restart"))
                (do
                  (set restarted-argv opts.argv)
                  (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                        f (assert (io.open out-path :w))]
                    (f:write (json.encode {:final-text "steered" :stop-reason "stop"}))
                    (f:close))
                  {:exit-code 0 :timed-out? false :duration-ms 20 :output ""})))
          (fn [name] (when (= name :scout) scout-cfg)))
        (let [api (fresh-captured)
              tool (registered-tool :subagent)
              r (tool.execute {:agent :scout :task "look around"} {:api api})
              snap (snapshot)
              run (. snap.runs 1)]
          (assert.is_false r.is-error?)
          (assert.are.equal "steered" (first-text r.content))
          (assert.are.equal 2 attempts)
          (assert.are.equal 1 (. r.details :restart-count))
          (assert.are.equal 1 (. r.details :steering-count))
          (assert.are.equal 1 run.restart-count)
          (assert.are.equal "focus on cwd" (. run.steering-notes 1 :note))
          (assert.is_truthy (string.find (table.concat restarted-argv " ")
                                         "Steering note for restarted subagent run" 1 true)))))

    (it "records cooperative cancellation distinctly from process failures"
      (fn []
        (let [marker {:type :cancel-marker}]
          (install-mocks
            (fn [_opts _yield]
              (error marker))
            (fn [name] (when (= name :scout) scout-cfg)))
          (fresh)
          (let [tool (registered-tool :subagent)
                (ok? err) (pcall tool.execute
                                  {:agent :scout :task "cancel during spawn"}
                                  {}
                                  (fn [] nil))]
            (assert.is_false ok?)
            (assert.are.equal marker err)
            (let [snap (snapshot)]
              (assert.are.equal 0 snap.active-count)
              (assert.are.equal :cancelled (. snap.runs 1 :status)))))))

    (it "records process failures as failed run results"
      (fn []
        (install-mocks
          (fn [_opts _yield]
            (error "spawn failed: no such file"))
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "fail before output"})
              snap (snapshot)
              text (first-text r.content)]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find text "Subagent failed before producing a result" 1 true))
          (assert.is_truthy (string.find text "spawn failed" 1 true))
          (assert.are.equal 0 snap.active-count)
          (assert.are.equal :failed (. snap.runs 1 :status)))))

    (it "resolves no override by inheriting parent provider and model"
      (fn []
        (var seen-argv nil)
        (install-mocks
          (fn [opts _yield]
            (set seen-argv opts.argv)
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "ok" :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 1 :output ""})
          (fn [name]
            (when (= name :plain)
              {:name "plain" :description "Plain" :body "You are plain."})))
        (fresh)
        (let [r (execute-tool {:agent :plain :task "do it"}
                              {:agent {:provider-name :anthropic
                                       :model "claude-sonnet-4-5"}})]
          (assert.is_false r.is-error?)
          (assert.is_true (argv-has? seen-argv "--provider" :anthropic))
          (assert.is_true (argv-has? seen-argv "--model" "claude-sonnet-4-5"))
          (assert.are.equal :anthropic (. r.details :provider))
          (assert.are.equal "claude-sonnet-4-5" (. r.details :model))
          (assert.are.equal :inherited (. r.details :provider-source))
          (assert.are.equal :inherited (. r.details :model-source)))))

    (it "resolves model-only override with inherited provider"
      (fn []
        (var seen-argv nil)
        (install-mocks
          (fn [opts _yield]
            (set seen-argv opts.argv)
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "ok" :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 1 :output ""})
          (fn [name]
            (when (= name :modeler)
              {:name "modeler" :description "Modeler"
               :model "claude-haiku-4-5" :body "You are modeler."})))
        (fresh)
        (let [r (execute-tool {:agent :modeler :task "do it"}
                              {:agent {:provider-name :anthropic
                                       :model "claude-sonnet-4-5"}})]
          (assert.is_false r.is-error?)
          (assert.is_true (argv-has? seen-argv "--provider" :anthropic))
          (assert.is_true (argv-has? seen-argv "--model" "claude-haiku-4-5"))
          (assert.are.equal :anthropic (. r.details :provider))
          (assert.are.equal "claude-haiku-4-5" (. r.details :model))
          (assert.are.equal :inherited (. r.details :provider-source))
          (assert.are.equal :frontmatter (. r.details :model-source)))))

    (it "resolves provider-only override without inherited model"
      (fn []
        (var seen-argv nil)
        (install-mocks
          (fn [opts _yield]
            (set seen-argv opts.argv)
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "ok" :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 1 :output ""})
          (fn [name]
            (when (= name :providered)
              {:name "providered" :description "Providered"
               :provider :openai :body "You are providered."})))
        (fresh)
        (let [r (execute-tool {:agent :providered :task "do it"}
                              {:agent {:provider-name :anthropic
                                       :model "claude-sonnet-4-5"}})]
          (assert.is_false r.is-error?)
          (assert.is_true (argv-has? seen-argv "--provider" :openai))
          (assert.is_false (argv-flag? seen-argv "--model"))
          (assert.are.equal :openai (. r.details :provider))
          (assert.is_nil (. r.details :model))
          (assert.are.equal :frontmatter (. r.details :provider-source))
          (assert.are.equal :omitted-provider-override (. r.details :model-source)))))

    (it "resolves provider and model overrides from frontmatter"
      (fn []
        (var seen-argv nil)
        (install-mocks
          (fn [opts _yield]
            (set seen-argv opts.argv)
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "ok" :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 1 :output ""})
          (fn [name]
            (when (= name :pinned)
              {:name "pinned" :description "Pinned"
               :provider :openai :model "gpt-5"
               :body "You are pinned."})))
        (fresh)
        (let [r (execute-tool {:agent :pinned :task "do it"}
                              {:agent {:provider-name :anthropic
                                       :model "claude-sonnet-4-5"}})]
          (assert.is_false r.is-error?)
          (assert.is_true (argv-has? seen-argv "--provider" :openai))
          (assert.is_true (argv-has? seen-argv "--model" "gpt-5"))
          (assert.are.equal :openai (. r.details :provider))
          (assert.are.equal "gpt-5" (. r.details :model))
          (assert.are.equal :frontmatter (. r.details :provider-source))
          (assert.are.equal :frontmatter (. r.details :model-source)))))

    (it "passes requested cwd through spawn, PWD, task context, and details"
      (fn []
        (var seen-opts nil)
        (install-mocks
          (fn [opts _yield]
            (set seen-opts opts)
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "cwd ok" :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 5 :output "ignored"})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "review the diff" :cwd "/tmp"})
              joined (table.concat seen-opts.argv " ")]
          (assert.is_false r.is-error?)
          (assert.are.equal "/tmp" seen-opts.cwd)
          (assert.are.equal "/tmp" (. seen-opts.env :PWD))
          (assert.is_truthy (string.find joined "Subagent launch context" 1 true))
          (assert.is_truthy (string.find joined "Requested cwd: /tmp" 1 true))
          (assert.is_truthy (string.find joined "Child PWD: /tmp" 1 true))
          (assert.is_truthy (string.find joined "review the diff" 1 true))
          (assert.are.equal "/tmp" (. r.details :requested-cwd))
          (assert.are.equal "/tmp" (. r.details :cwd))
          (assert.is_truthy (. r.details :physical-cwd)))))

    (it "flags an unknown agent as an error"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] nil))
        (fresh)
        (let [r (execute-tool {:agent :ghost :task "x"})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "unknown agent" 1 true)))))

    (it "surfaces invalid agent definition errors"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name]
            (values nil {:file "/tmp/bad.md"
                         :reason "missing required frontmatter field `name`"})))
        (fresh)
        (let [r (execute-tool {:agent :bad :task "x"})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                         "invalid agent definition /tmp/bad.md"
                                         1 true))
          (assert.are.equal :bad (. r.details :agent))
          (assert.are.equal "/tmp/bad.md" (. r.details :path))
          (assert.are.equal "missing required frontmatter field `name`"
                            (. r.details :reason)))))

    (it "flags a nonzero child exit as an error with diagnostics"
      (fn []
        (install-mocks
          (fn [opts _yield]
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:error "boom" :stop-reason "error"}))
              (f:close))
            {:exit-code 1 :timed-out? false :duration-ms 3 :output "boom"})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "do it"})
              text (first-text r.content)]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find text "Subagent failed" 1 true))
          (assert.is_truthy (string.find text "exit code: 1" 1 true))
          (assert.is_truthy (string.find text "Child message" 1 true))
          (assert.are.equal 1 (. r.details :exit-code))
          (assert.are.equal :ok (. r.details :json-status)))))

    (it "diagnoses missing JSON output"
      (fn []
        (install-mocks
          (fn [_opts _yield]
            {:exit-code 0 :timed-out? false :duration-ms 7
             :output "raw child output" :truncated? true})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "do it"})
              text (first-text r.content)]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find text "Subagent failed" 1 true))
          (assert.is_truthy (string.find text "json output: missing" 1 true))
          (assert.is_truthy (string.find text "output truncated: true" 1 true))
          (assert.is_truthy (string.find text "raw child output" 1 true))
          (assert.are.equal :missing (. r.details :json-status))
          (assert.are.equal "raw child output" (. r.details :output-tail))
          (assert.is_nil (. r.details :empty-final-text?)))))

    (it "diagnoses malformed JSON output"
      (fn []
        (install-mocks
          (fn [opts _yield]
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write "{not json")
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 8
             :output "parser failed" :truncated? false})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "do it"})
              text (first-text r.content)]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find text "json output: invalid" 1 true))
          (assert.is_truthy (string.find text "json error" 1 true))
          (assert.are.equal :invalid (. r.details :json-status))
          (assert.is_truthy (. r.details :json-error)))))

    (it "uses a per-call timeout as a bounded named-agent budget"
      (fn []
        (var seen-timeout nil)
        (install-mocks
          (fn [opts _yield]
            (set seen-timeout opts.timeout-seconds)
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "done" :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 1 :output ""})
          (fn [name]
            (when (= name :scout)
              {:name "scout" :description "Recon" :timeout-seconds 90
               :body "You are a scout."})))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "do it" :timeout-seconds 12})]
          (assert.is_false r.is-error?)
          (assert.are.equal 12 seen-timeout)
          (assert.are.equal 12 (. r.details :timeout-seconds)))))

    (it "applies and caps per-call timeouts for inline agents"
      (fn []
        (let [seen-timeouts []]
          (install-mocks
            (fn [opts _yield]
              (table.insert seen-timeouts opts.timeout-seconds)
              (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                    f (assert (io.open out-path :w))]
                (f:write (json.encode {:final-text "done" :stop-reason "stop"}))
                (f:close))
              {:exit-code 0 :timed-out? false :duration-ms 1 :output ""})
            (fn [_name] (error "should not discover inline agent")))
          (fresh)
          (execute-tool {:prompt "Be brief" :task "do it" :timeout-seconds 12})
          (execute-tool {:prompt "Be brief" :task "do it" :timeout-seconds 999})
          (assert.are.same [12 300] seen-timeouts))))

    (it "does not let a per-call timeout exceed agent policy"
      (fn []
        (var seen-timeout nil)
        (install-mocks
          (fn [opts _yield]
            (set seen-timeout opts.timeout-seconds)
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "done" :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 1 :output ""})
          (fn [name]
            (when (= name :scout)
              {:name "scout" :description "Recon" :timeout-seconds 30
               :body "You are a scout."})))
        (fresh)
        (execute-tool {:agent :scout :task "do it" :timeout-seconds 120})
        (assert.are.equal 30 seen-timeout)))

    (it "returns compact partial child progress on timeout"
      (fn []
        (install-mocks
          (fn [opts yield]
            (let [event-path (. opts.env :FEN_SUBAGENT_EVENT_PATH)
                  ef (assert (io.open event-path :a))]
              (ef:write (json.encode {:type :tool-call :name :grep
                                      :summary "searched goal sources"}) "\n")
              (ef:write (json.encode {:type :assistant-text
                                      :summary "Found the state transition."}) "\n")
              (ef:close))
            (when yield (yield))
            {:exit-code nil :signal 15 :timed-out? true :duration-ms 12000
             :output "" :truncated? false})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "do it" :timeout-seconds 12})
              text (first-text r.content)]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find text "timed out: true" 1 true))
          (assert.is_truthy (string.find text "timeout seconds: 12" 1 true))
          (assert.is_truthy (string.find text "Latest child progress" 1 true))
          (assert.is_truthy (string.find text "grep: searched goal sources" 1 true))
          (assert.is_truthy (string.find text "Found the state transition" 1 true))
          (assert.is_truthy (string.find text "retry with a narrower task" 1 true))
          (assert.is_true (. r.details :partial-progress?))
          (assert.is_true (. r.details :partial-assistant-text?))
          (assert.are.equal 12 (. r.details :timeout-seconds)))))

    (it "does not mistake lifecycle events for partial progress"
      (fn []
        (install-mocks
          (fn [_opts _yield]
            {:exit-code nil :signal 15 :timed-out? true :duration-ms 5000
             :output "" :truncated? false})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "do it" :timeout-seconds 5})
              text (first-text r.content)]
          (assert.is_true r.is-error?)
          (assert.is_false (. r.details :partial-progress?))
          (assert.is_false (. r.details :partial-assistant-text?))
          (assert.is_nil (string.find text "Latest child progress" 1 true))
          (assert.is_nil (string.find text "continue from the progress above" 1 true)))))

    (it "remembers assistant progress after it leaves the bounded event tail"
      (fn []
        (install-mocks
          (fn [opts yield]
            (let [event-path (. opts.env :FEN_SUBAGENT_EVENT_PATH)
                  ef (assert (io.open event-path :a))]
              (ef:write (json.encode {:type :assistant-text
                                      :summary "early useful finding"}) "\n")
              (for [i 1 55]
                (ef:write (json.encode {:type :tool-call :name :grep
                                        :summary (.. "search " i)}) "\n"))
              (ef:close))
            (when yield (yield))
            {:exit-code nil :signal 15 :timed-out? true :duration-ms 5000
             :output "" :truncated? false})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "do it" :timeout-seconds 5})]
          (assert.is_true r.is-error?)
          (assert.is_true (. r.details :partial-progress?))
          (assert.is_true (. r.details :partial-assistant-text?)))))

    (it "distinguishes empty successful final text"
      (fn []
        (install-mocks
          (fn [opts _yield]
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "" :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 9 :output ""})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "do it"})
              text (first-text r.content)]
          (assert.is_false r.is-error?)
          (assert.is_truthy (string.find text "empty final text" 1 true))
          (assert.is_true (. r.details :empty-final-text?))
          (assert.are.equal :ok (. r.details :json-status)))))

    (it "launches and completes a background run through runtime ticks"
      (fn []
        (var ticks 0)
        (var seen-task nil)
        (install-mocks
          (fn [_opts _yield] (error "blocking path should not run"))
          (fn [name] (when (= name :scout) scout-cfg))
          nil nil
          (fn [opts]
            (set seen-task (table.concat opts.argv " "))
            {:abort (fn [] nil)
             :resume (fn []
                       (set ticks (+ ticks 1))
                       (if (= ticks 1)
                           (values false nil)
                           (do
                             (let [f (assert (io.open (. opts.env :FEN_JSON_OUTPUT_PATH) :w))]
                               (f:write (json.encode {:final-text "background finding"
                                                      :stop-reason "stop"}))
                               (f:close))
                             (values true {:exit-code 0 :timed-out? false
                                           :duration-ms 25 :output ""}))))}))
        (fresh)
        (let [steering (require :fen.extensions.steering.service)
              tool (registered-tool :subagent)]
          (steering.clear-queues!)
          (let [r (tool.execute {:agent :scout :task "inspect it" :background true}
                                {})]
            (assert.is_false r.is-error?)
            (assert.are.equal "subagent-1" (. r.details :run-id))
            (assert.are.equal 1 (. (snapshot) :active-count))
            (assert.is_truthy (string.find seen-task "Background authority" 1 true))
            (events.emit {:type :runtime-tick})
            (assert.are.equal 1 (. (snapshot) :active-count))
            (events.emit {:type :runtime-tick})
            (let [snap (snapshot)
                  run (. snap.runs 1)
                  queued (steering.queue-snapshot)]
              (assert.are.equal 0 snap.active-count)
              (assert.are.equal :completed run.status)
              (assert.are.equal "background finding" run.result)
              (assert.is_nil run.handle)
              (assert.is_nil run.current-task)
              (assert.are.equal 1 (length queued.follow-up))
              (assert.is_truthy (string.find (. queued.follow-up 1)
                                             "background finding" 1 true)))
            (steering.clear-queues!)))))

    (it "cancels active background jobs before registering reloaded behavior"
      (fn []
        (var aborted? false)
        (install-mocks
          (fn [_opts _yield] (error "blocking path should not run"))
          (fn [name] (when (= name :scout) scout-cfg))
          nil nil
          (fn [_opts]
            {:abort (fn [] (set aborted? true))
             :resume (fn []
                       (values true {:exit-code nil :signal 9 :cancelled? true
                                     :timed-out? false :duration-ms 1 :output ""}))}))
        (fresh)
        (let [tool (registered-tool :subagent)]
          (tool.execute {:agent :scout :task "wait" :background true} {})
          (tset package.loaded :fen.extensions.subagent nil)
          (let [reloaded (require :fen.extensions.subagent)
                api (test-api.make-runtime-api :subagent)]
            (reloaded.register api))
          (assert.is_true aborted?))))

    (it "rejects background runs for a presenter without idle ticks"
      (fn []
        (var spawned? false)
        (install-mocks
          (fn [_opts _yield] (error "blocking path should not run"))
          (fn [name] (when (= name :scout) scout-cfg))
          nil nil
          (fn [_opts] (set spawned? true)))
        (fresh)
        (let [tool (registered-tool :subagent)
              r (tool.execute {:agent :scout :task "inspect" :background true}
                              {:state {:opts {:presenter :stdio}}})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                         "ticking presenter" 1 true))
          (assert.is_false spawned?))))

    (it "preserves bounded canonical display payloads"
      (fn []
        (let [delta (subagent-events.normalize
                      {:type :assistant-text-delta :delta "hello"
                       :content-index 2} {})
              call (subagent-events.normalize
                     {:type :tool-call :id "c1" :name "read"
                      :arguments {:path "README.md"}} {})
              result (subagent-events.normalize
                       {:type :tool-result :id "c1" :name "read"
                        :result {:content [{:type :text
                                           :text (string.rep "x" 20000)}]}} {})]
          (assert.are.equal "hello" delta.delta)
          (assert.are.equal 2 delta.content-index)
          (assert.are.equal "README.md" call.arguments.path)
          (assert.are.equal :text (. result.result.content 1 :type))
          (assert.is_true result.transport-truncated?)
          (assert.is_true (< (length (json.encode result))
                             subagent-events.EVENT-PAYLOAD-BYTES)))))

    (it "falls back to a bounded record when encoded metadata is oversized"
      (fn []
        (let [p (os.tmpname)
              huge-key (string.rep "k" 70000)]
          (assert.is_true
            (subagent-events.append! p {:type :tool-call :name "read"
                                        :arguments {huge-key "value"}} {}))
          (let [f (assert (io.open p :r))
                line (f:read "*l")]
            (f:close)
            (os.remove p)
            (assert.is_true (< (length line) subagent-events.EVENT-RECORD-BYTES))
            (assert.is_true (. (json.decode line) :transport-truncated?))))))

    (it "sequences retained events without mutating callers"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] scout-cfg))
        (fresh)
        (let [run-state (require :fen.extensions.subagent.state)
              run (run-state.start! {:agent "scout" :task "inspect"
                                     :cwd "/tmp" :background? false})
              ev {:type :assistant-text :text "done"}]
          (run-state.append-event! run.id ev)
          (assert.is_nil ev.transport-seq)
          (assert.are.equal 1 (. (run-state.find run.id) :events 1 :transport-seq)))))

    (it "drains background event files in bounded batches"
      (fn []
        (let [p (os.tmpname)
              f (assert (io.open p :w))]
          (for [i 1 100]
            (f:write (json.encode {:type :tool-call :name (.. "tool-" i)}) "\n"))
          (f:close)
          (let [(first first-offset first-errors first-status) (subagent-events.drain p 0)
                (second _second-offset second-errors second-status)
                (subagent-events.drain p first-offset)]
            (os.remove p)
            (assert.are.equal :ok first-status)
            (assert.are.equal 64 (length first))
            (assert.are.equal 0 (length first-errors))
            (assert.are.equal :ok second-status)
            (assert.are.equal 36 (length second))
            (assert.are.equal 0 (length second-errors))))))

    (it "reports a background launch failure without queuing duplicate completion"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "blocking path should not run"))
          (fn [name] (when (= name :scout) scout-cfg))
          nil nil
          (fn [_opts] (error "spawn exploded")))
        (fresh)
        (let [steering (require :fen.extensions.steering.service)
              tool (registered-tool :subagent)]
          (steering.clear-queues!)
          (let [r (tool.execute {:agent :scout :task "inspect" :background true} {})]
            (assert.is_true r.is-error?)
            (assert.is_truthy (string.find (first-text r.content)
                                           "spawn exploded" 1 true))
            (assert.are.equal 0 (. (snapshot) :active-count))
            (assert.are.equal 0 (length (. (steering.queue-snapshot) :follow-up)))))))

    (it "restarts a detached run when steering is queued"
      (fn []
        (var attempts 0)
        (var first-aborted? false)
        (var second-task nil)
        (install-mocks
          (fn [_opts _yield] (error "blocking path should not run"))
          (fn [name] (when (= name :scout) scout-cfg))
          nil nil
          (fn [opts]
            (set attempts (+ attempts 1))
            (if (= attempts 1)
                {:abort (fn [] (set first-aborted? true))
                 :resume (fn []
                           (if first-aborted?
                               (values true {:exit-code nil :signal 9
                                             :cancelled? true :timed-out? false
                                             :duration-ms 1 :output ""})
                               (values false nil)))}
                (do
                  (set second-task (table.concat opts.argv " "))
                  {:abort (fn [] nil)
                   :resume (fn []
                             (let [f (assert (io.open (. opts.env :FEN_JSON_OUTPUT_PATH) :w))]
                               (f:write (json.encode {:final-text "steered result"
                                                      :stop-reason "stop"}))
                               (f:close))
                             (values true {:exit-code 0 :timed-out? false
                                           :duration-ms 3 :output ""}))}))))
        (fresh)
        (let [tool (registered-tool :subagent)]
          (tool.execute {:agent :scout :task "inspect" :background true} {})
          (command-registry.dispatch "/subagents steer subagent-1 focus on tests" {})
          (events.emit {:type :runtime-tick})
          (assert.is_true first-aborted?)
          (assert.are.equal 2 attempts)
          (assert.is_truthy (string.find second-task
                                         "Steering note for restarted subagent run"
                                         1 true))
          (events.emit {:type :runtime-tick})
          (let [run (. (snapshot) :runs 1)]
            (assert.are.equal :completed run.status)
            (assert.are.equal 1 run.restart-count)
            (assert.are.equal "steered result" run.result)))))

    (it "cancels a detached run by id and finalizes it on the next tick"
      (fn []
        (var aborted? false)
        (install-mocks
          (fn [_opts _yield] (error "blocking path should not run"))
          (fn [name] (when (= name :scout) scout-cfg))
          nil nil
          (fn [_opts]
            {:abort (fn [] (set aborted? true))
             :resume (fn []
                       (if aborted?
                           (values true {:exit-code nil :signal 9
                                         :cancelled? true :timed-out? false
                                         :duration-ms 2 :output ""})
                           (values false nil)))}))
        (let [api (fresh-captured)
              tool (registered-tool :subagent)]
          (tool.execute {:agent :scout :task "wait" :background true} {})
          (command-registry.dispatch "/subagents cancel subagent-1" {})
          (assert.is_true aborted?)
          (events.emit {:type :runtime-tick})
          (let [run (. (snapshot) :runs 1)]
            (assert.are.equal :cancelled run.status))
          (command-registry.dispatch "/subagents show subagent-1" {})
          (assert.is_truthy (string.find (last-assistant-text api)
                                         "status: cancelled" 1 true)))))

    (it "supports agentic list, show, and clear management actions"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] scout-cfg))
        (fresh)
        (let [run-state (require :fen.extensions.subagent.state)
              run (run-state.start! {:agent "scout" :task "inspect"
                                     :cwd "/tmp" :background? false})]
          (run-state.finish! run.id :completed {:result "done"})
          (let [listed (execute-tool {:action "list"})
                shown (execute-tool {:action "show" :run-id run.id})]
            (assert.is_false listed.is-error?)
            (assert.is_truthy (string.find (first-text listed.content)
                                           run.id 1 true))
            (assert.are.equal 1 (length listed.details.runs))
            (assert.is_false shown.is-error?)
            (assert.are.equal run.id shown.details.run.id)
            (assert.is_truthy (string.find (first-text shown.content)
                                           "status: completed" 1 true)))
          (assert.is_false (. (execute-tool {:action "remove" :run-id run.id})
                              :is-error?))
          (assert.are.equal 0 (length (. (snapshot) :runs)))
          (let [another (run-state.start! {:agent "scout" :task "another"
                                           :cwd "/tmp" :background? false})]
            (run-state.finish! another.id :completed {:result "done"}))
          (assert.is_false (. (execute-tool {:action "clear"}) :is-error?))
          (assert.are.equal 0 (length (. (snapshot) :runs)))
          (let [next-run (run-state.start! {:agent "scout" :task "next"
                                            :cwd "/tmp" :background? false})]
            (assert.are_not.equal run.id next-run.id)))))

    (it "steers, waits for, and retries detached runs agentically"
      (fn []
        (var attempts 0)
        (install-mocks
          (fn [_opts _yield] (error "blocking path should not run"))
          (fn [name] (when (= name :scout) scout-cfg))
          nil nil
          (fn [opts]
            (set attempts (+ attempts 1))
            {:abort (fn [] nil)
             :resume (fn []
                       (let [f (assert (io.open (. opts.env :FEN_JSON_OUTPUT_PATH) :w))]
                         (f:write (json.encode {:final-text (.. "done-" attempts)
                                                :stop-reason "stop"}))
                         (f:close))
                       (values true {:exit-code 0 :timed-out? false
                                     :duration-ms 2 :output ""}))}))
        (fresh)
        (let [tool (registered-tool :subagent)
              launched (tool.execute {:agent :scout :task "inspect"
                                      :background true} {})
              first-id launched.details.run-id]
          (let [steered (tool.execute {:action "steer" :run-id first-id
                                       :note "focus"} {})]
            (assert.is_false steered.is-error?)
            (assert.are.equal 1 (length steered.details.run.steering-notes)))
          (let [waited (tool.execute {:action "wait" :run-id first-id} {})]
            (assert.is_false waited.is-error?)
            (assert.are.equal :completed waited.details.run.status))
          (let [retried (tool.execute {:action "retry" :run-id first-id} {})]
            (assert.is_false retried.is-error?)
            (assert.are.equal first-id retried.details.retry-of)
            (assert.are_not.equal first-id retried.details.run-id)
            (let [waited (tool.execute {:action "wait"
                                        :run-id retried.details.run-id} {})]
              (assert.are.equal :completed waited.details.run.status)
              (assert.are.equal first-id waited.details.run.retry-of)))
          ;; Steering restarts once, then retry launches a third process.
          (assert.are.equal 3 attempts))))

    (it "rejects steering after the restart limit"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] scout-cfg))
        (fresh)
        (let [run-state (require :fen.extensions.subagent.state)
              run (run-state.start! {:agent "scout" :task "inspect"
                                     :cwd "/tmp" :background? true})
              tool (registered-tool :subagent)]
          (set run.restart-count 3)
          (let [steered (tool.execute {:action "steer" :run-id run.id
                                       :note "again"} {})]
            (assert.is_true steered.is-error?)
            (assert.are.equal :restart-limit steered.details.reason)
            (assert.are.equal 0 (length (or run.pending-steering [])))))))

    (it "reset cancels detached runs and clears their history"
      (fn []
        (var aborted? false)
        (install-mocks
          (fn [_opts _yield] (error "blocking path should not run"))
          (fn [name] (when (= name :scout) scout-cfg))
          nil nil
          (fn [_opts]
            {:abort (fn [] (set aborted? true))
             :resume (fn []
                       (if aborted?
                           (values true {:exit-code nil :signal 9
                                         :cancelled? true :timed-out? false
                                         :duration-ms 2 :output ""})
                           (values false nil)))}))
        (fresh)
        (let [tool (registered-tool :subagent)]
          (tool.execute {:agent :scout :task "wait" :background true} {})
          (let [reset (tool.execute {:action "reset"} {})]
            (assert.is_false reset.is-error?)
            (assert.are.equal 1 reset.details.cancelled))
          (assert.is_true aborted?)
          (assert.are.equal 0 (. (snapshot) :active-count))
          (assert.are.equal 0 (length (. (snapshot) :runs))))))

    (it "cancels, reaps, and clears detached runs on conversation reset"
      (fn []
        (var aborted? false)
        (install-mocks
          (fn [_opts _yield] (error "blocking path should not run"))
          (fn [name] (when (= name :scout) scout-cfg))
          nil nil
          (fn [_opts]
            {:abort (fn [] (set aborted? true))
             :resume (fn []
                       (if aborted?
                           (values true {:exit-code nil :signal 9
                                         :cancelled? true :timed-out? false
                                         :duration-ms 2 :output ""})
                           (values false nil)))}))
        (fresh)
        (let [tool (registered-tool :subagent)]
          (tool.execute {:agent :scout :task "wait" :background true} {})
          (events.emit {:type :reset-conversation :reason :resume})
          (assert.is_false aborted?)
          (assert.are.equal 1 (. (snapshot) :active-count))
          (events.emit {:type :reset-conversation :reason :new})
          (assert.is_true aborted?)
          (assert.are.equal 0 (. (snapshot) :active-count))
          (assert.are.equal 0 (length (. (snapshot) :runs))))))

    (it "marks orphaned background runs failed without touching blocking runs"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] scout-cfg))
        (fresh)
        (let [run-state (require :fen.extensions.subagent.state)
              bg (run-state.start! {:agent "scout" :task "bg"
                                    :cwd "/tmp" :background? true})
              blocking (run-state.start! {:agent "scout" :task "blocking"
                                          :cwd "/tmp" :background? false})]
          (assert.are.equal 1 (run-state.reconcile-background!))
          (assert.are.equal :failed (. (run-state.find bg.id) :status))
          (assert.are.equal :running (. (run-state.find blocking.id) :status)))))

    (it "errors when the task is missing"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] scout-cfg))
        (fresh)
        (let [r (execute-tool {:agent :scout})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "task" 1 true)))))

    (it "normalizes provider and snake_case usage fields"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] scout-cfg))
        (fresh)
        (let [run-state (require :fen.extensions.subagent.state)
              canon (run-state.canonical-usage
                      {:prompt_tokens 100 :completion_tokens 40
                       :cached_tokens 20 :total_tokens 140 :latency-ms 999})]
          (assert.are.equal 100 canon.input)
          (assert.are.equal 40 canon.output)
          (assert.are.equal 20 canon.cache-read)
          (assert.are.equal 140 canon.total-tokens)
          (assert.is_nil (. canon :latency-ms))
          ;; Derives a total from input+output when none is reported.
          (let [derived (run-state.canonical-usage {:input 5 :output 3})]
            (assert.are.equal 8 derived.total-tokens))
          (assert.is_nil (run-state.canonical-usage {:latency-ms 12}))
          (assert.is_nil (run-state.canonical-usage nil)))))

    (it "reconciles final-result usage without double counting per-turn events"
      (fn []
        (install-mocks
          (fn [opts yield]
            (let [ef (assert (io.open (. opts.env :FEN_SUBAGENT_EVENT_PATH) :a))]
              ;; Two completed provider turns, each reporting per-turn usage.
              (ef:write (json.encode {:type :llm-end
                                      :usage {:input 40 :output 5
                                              :total-tokens 45}}) "\n")
              (ef:write (json.encode {:type :llm-end
                                      :usage {:input 42 :output 2
                                              :total-tokens 44}}) "\n")
              (ef:close))
            (when yield (yield))
            ;; Final blob is the cumulative sum the child computed.
            (let [f (assert (io.open (. opts.env :FEN_JSON_OUTPUT_PATH) :w))]
              (f:write (json.encode {:final-text "done"
                                     :usage {:input 82 :output 7
                                             :total-tokens 89}
                                     :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 10 :output ""})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "count tokens"})]
          (assert.is_false r.is-error?)
          ;; Authoritative final total, not final + per-turn sum.
          (assert.are.equal 89 (. r.details :usage :total-tokens))
          (assert.are.equal 82 (. r.details :usage :input))
          (assert.are.equal :final-result (. r.details :usage-source))
          (assert.is_true (. r.details :usage-complete?))
          ;; Turn count still comes from the event stream.
          (assert.are.equal 2 (. r.details :usage-turns)))))

    (it "retains completed-turn usage when a child times out without a blob"
      (fn []
        (install-mocks
          (fn [opts yield]
            (let [ef (assert (io.open (. opts.env :FEN_SUBAGENT_EVENT_PATH) :a))]
              (ef:write (json.encode {:type :llm-end
                                      :usage {:input 30 :output 4
                                              :cache-read 12
                                              :total-tokens 34}}) "\n")
              (ef:write (json.encode {:type :llm-end
                                      :usage {:input 20 :output 6
                                              :total-tokens 26}}) "\n")
              (ef:close))
            (when yield (yield))
            {:exit-code nil :signal 15 :timed-out? true :duration-ms 12000
             :output "" :truncated? false})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "do it" :timeout-seconds 12})]
          (assert.is_true r.is-error?)
          ;; Summed from the two completed turns; final turn never reported.
          (assert.are.equal 60 (. r.details :usage :total-tokens))
          (assert.are.equal 50 (. r.details :usage :input))
          (assert.are.equal 12 (. r.details :usage :cache-read))
          (assert.are.equal :events (. r.details :usage-source))
          (assert.is_false (. r.details :usage-complete?))
          (assert.are.equal 2 (. r.details :usage-turns))
          (assert.are.equal :provider-reported
                            (. r.details :usage-provenance :input)))))

    (it "retains completed-turn usage when a child fails without a blob"
      (fn []
        (install-mocks
          (fn [opts yield]
            (let [ef (assert (io.open (. opts.env :FEN_SUBAGENT_EVENT_PATH) :a))]
              (ef:write (json.encode {:type :llm-end
                                      :usage {:input 15 :output 3
                                              :total-tokens 18}}) "\n")
              (ef:close))
            (when yield (yield))
            {:exit-code 0 :timed-out? false :duration-ms 7
             :output "raw" :truncated? false})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        ;; No JSON blob written -> failure path, but usage survives.
        (let [r (execute-tool {:agent :scout :task "do it"})]
          (assert.is_true r.is-error?)
          (assert.are.equal 18 (. r.details :usage :total-tokens))
          (assert.are.equal :events (. r.details :usage-source)))))

    (it "combines earlier-attempt events with a final blob across a restart"
      (fn []
        (var attempts 0)
        (install-mocks
          (fn [opts yield]
            (set attempts (+ attempts 1))
            (let [ef (assert (io.open (. opts.env :FEN_SUBAGENT_EVENT_PATH) :a))]
              (if (= attempts 1)
                  (ef:write (json.encode {:type :llm-end
                                          :usage {:input 90 :output 10
                                                  :total-tokens 100}}) "\n")
                  (ef:write (json.encode {:type :llm-end
                                          :usage {:input 45 :output 5
                                                  :total-tokens 50}}) "\n"))
              (ef:close))
            (if (= attempts 1)
                (do
                  (command-registry.dispatch
                    "/subagents steer subagent-1 narrow it" {:busy? true})
                  (when yield (yield))
                  (error "expected steering yield to restart"))
                (do
                  ;; Final attempt writes an authoritative cumulative blob for
                  ;; its own run only.
                  (let [f (assert (io.open (. opts.env :FEN_JSON_OUTPUT_PATH) :w))]
                    (f:write (json.encode {:final-text "steered"
                                           :usage {:input 45 :output 5
                                                   :total-tokens 50}
                                           :stop-reason "stop"}))
                    (f:close))
                  {:exit-code 0 :timed-out? false :duration-ms 20 :output ""})))
          (fn [name] (when (= name :scout) scout-cfg)))
        (let [api (fresh-captured)
              tool (registered-tool :subagent)
              r (tool.execute {:agent :scout :task "look"} {:api api})]
          (assert.is_false r.is-error?)
          (assert.are.equal 2 attempts)
          ;; Must be attempt-1 events (100) + attempt-2 blob (50), not just 50.
          (assert.are.equal 150 (. r.details :usage :total-tokens))
          (assert.are.equal 135 (. r.details :usage :input))
          (assert.are.equal :mixed (. r.details :usage-source))
          (assert.is_true (. r.details :usage-complete?))
          (assert.are.equal 2 (. r.details :usage-turns)))))

    (it "flags a derived total as estimated provenance"
      (fn []
        (install-mocks
          (fn [opts _yield]
            (let [f (assert (io.open (. opts.env :FEN_JSON_OUTPUT_PATH) :w))]
              ;; No total reported -> canonicalization derives input+output.
              (f:write (json.encode {:final-text "ok"
                                     :usage {:input 6 :output 4}
                                     :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 3 :output ""})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "do it"})]
          (assert.is_false r.is-error?)
          (assert.are.equal 10 (. r.details :usage :total-tokens))
          (assert.are.equal :estimated
                            (. r.details :usage-provenance :total-tokens))
          (assert.are.equal :provider-reported
                            (. r.details :usage-provenance :input)))))

    (it "groups usage by provider as well as model and outcome"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] scout-cfg))
        (let [api (fresh-captured)
              run-state (require :fen.extensions.subagent.state)]
          (let [a (run-state.start! {:agent "scout" :task "one"
                                     :cwd "/tmp" :background? false})]
            (run-state.accumulate-usage! a.id {:input 80 :output 5
                                               :total-tokens 85})
            (run-state.finish! a.id :completed
                               {:provider "sakana" :model "fugu"
                                :usage {:input 80 :output 5 :total-tokens 85}}))
          (let [b (run-state.start! {:agent "scout" :task "two"
                                     :cwd "/tmp" :background? false})]
            (run-state.accumulate-usage! b.id {:input 40 :output 3
                                               :total-tokens 43})
            (run-state.finish! b.id :completed
                               {:provider "openai" :model "fugu"
                                :usage {:input 40 :output 3 :total-tokens 43}}))
          (command-registry.dispatch "/subagents usage" {})
          (let [out (last-assistant-text api)]
            (assert.is_truthy (string.find out "By provider / model / outcome"
                                           1 true))
            (assert.is_truthy (string.find out "sakana / fugu / completed" 1 true))
            (assert.is_truthy (string.find out "openai / fugu / completed" 1 true))
            (assert.is_truthy (string.find out "provider" 1 true))))))

    (it "accumulates usage across steering restarts"
      (fn []
        (var attempts 0)
        (install-mocks
          (fn [opts yield]
            (set attempts (+ attempts 1))
            (let [ef (assert (io.open (. opts.env :FEN_SUBAGENT_EVENT_PATH) :a))]
              (ef:write (json.encode {:type :llm-end
                                      :usage {:input 10 :output 2
                                              :total-tokens 12}}) "\n")
              (ef:close))
            (if (= attempts 1)
                (do
                  (command-registry.dispatch
                    "/subagents steer subagent-1 narrow it" {:busy? true})
                  (when yield (yield))
                  (error "expected steering yield to restart"))
                (do
                  (let [f (assert (io.open (. opts.env :FEN_JSON_OUTPUT_PATH) :w))]
                    (f:write (json.encode {:final-text "steered"
                                           :stop-reason "stop"}))
                    (f:close))
                  {:exit-code 0 :timed-out? false :duration-ms 20 :output ""})))
          (fn [name] (when (= name :scout) scout-cfg)))
        (let [api (fresh-captured)
              tool (registered-tool :subagent)
              r (tool.execute {:agent :scout :task "look"} {:api api})]
          (assert.is_false r.is-error?)
          (assert.are.equal 2 attempts)
          ;; No final-result usage blob, so both restart turns are summed.
          (assert.are.equal :events (. r.details :usage-source))
          (assert.are.equal 24 (. r.details :usage :total-tokens))
          (assert.are.equal 2 (. r.details :usage-turns)))))

    (it "records no usage when the child never reports any"
      (fn []
        (install-mocks
          (fn [opts _yield]
            (let [f (assert (io.open (. opts.env :FEN_JSON_OUTPUT_PATH) :w))]
              (f:write (json.encode {:final-text "ok" :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 3 :output ""})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "do it"})]
          (assert.is_false r.is-error?)
          (assert.is_nil (. r.details :usage))
          (assert.is_nil (. r.details :usage-source)))))

    (it "surfaces cache fields and usage in show output and the snapshot"
      (fn []
        (install-mocks
          (fn [opts _yield]
            (let [f (assert (io.open (. opts.env :FEN_JSON_OUTPUT_PATH) :w))]
              (f:write (json.encode {:final-text "done"
                                     :usage {:input 100 :output 20
                                             :cache-read 50 :cache-write 10
                                             :total-tokens 120}
                                     :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 9 :output ""})
          (fn [name] (when (= name :scout) scout-cfg)))
        (let [api (fresh-captured)]
          (execute-tool {:agent :scout :task "do it"})
          (command-registry.dispatch "/subagents show subagent-1" {})
          (let [out (last-assistant-text api)]
            (assert.is_truthy (string.find out "Usage:" 1 true))
            (assert.is_truthy (string.find out "cache-read: 50" 1 true))
            (assert.is_truthy (string.find out "cache-write: 10" 1 true))
            (assert.is_truthy (string.find out "total-tokens: 120" 1 true))
            (assert.is_truthy (string.find out "provider-reported" 1 true)))
          ;; Introspection snapshot exposes the same data without scraping text.
          (let [snap (snapshot)
                run (. snap.runs 1)]
            (assert.are.equal 120 (. run.details :usage :total-tokens))
            (assert.are.equal :final-result (. run.details :usage-source))))))

    (it "renders a usage table with a workflow total"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] scout-cfg))
        (let [api (fresh-captured)
              run-state (require :fen.extensions.subagent.state)]
          (let [a (run-state.start! {:agent "scout" :task "one"
                                     :cwd "/tmp" :background? false})]
            (run-state.accumulate-usage! a.id {:input 80 :output 5
                                               :total-tokens 85})
            (run-state.finish! a.id :completed
                               {:model "fugu-ultra"
                                :usage {:input 80 :output 5 :total-tokens 85}}))
          (let [b (run-state.start! {:agent "scout" :task "two"
                                     :cwd "/tmp" :background? false})]
            (run-state.accumulate-usage! b.id {:input 40 :output 3
                                               :total-tokens 43})
            (run-state.finish! b.id :timed-out {:model "fugu-ultra"
                                                :timed-out? true}))
          (command-registry.dispatch "/subagents usage" {})
          (let [out (last-assistant-text api)]
            (assert.is_truthy (string.find out "Subagent usage" 1 true))
            (assert.is_truthy (string.find out "TOTAL" 1 true))
            (assert.is_truthy (string.find out "By provider / model / outcome" 1 true))
            (assert.is_truthy (string.find out "subagent-1" 1 true))
            (assert.is_truthy (string.find out "subagent-2" 1 true))))))

    (it "does not leak live usage tables through the introspection snapshot"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] scout-cfg))
        (fresh)
        (let [run-state (require :fen.extensions.subagent.state)
              a (run-state.start! {:agent "scout" :task "one"
                                   :cwd "/tmp" :background? false})]
          (run-state.accumulate-usage! a.id {:input 10 :output 2
                                             :total-tokens 12})
          (run-state.finish! a.id :completed
                             {:usage {:input 10 :output 2 :total-tokens 12}})
          ;; Mutating a snapshot must not corrupt persistent run state.
          (let [snap1 (snapshot)]
            (tset (. snap1.runs 1 :details :usage) :total-tokens 99999)
            (tset (. snap1.runs 1 :usage-acc :totals) :total-tokens 88888))
          (let [snap2 (snapshot)]
            (assert.are.equal 12 (. snap2.runs 1 :details :usage :total-tokens))
            (assert.are.equal 12 (. snap2.runs 1 :usage-acc :totals
                                    :total-tokens))))))

    (it "returns structured usage rows from action=usage"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] scout-cfg))
        (fresh)
        (let [run-state (require :fen.extensions.subagent.state)
              a (run-state.start! {:agent "scout" :task "one"
                                   :cwd "/tmp" :background? false})]
          (run-state.accumulate-usage! a.id {:input 12 :output 4
                                             :total-tokens 16})
          (run-state.finish! a.id :timed-out {:timed-out? true})
          (let [r (execute-tool {:action "usage"})]
            (assert.is_false r.is-error?)
            (assert.are.equal 1 (length r.details.runs))
            (let [row (. r.details.runs 1)]
              (assert.are.equal a.id row.run-id)
              (assert.are.equal 16 (. row.usage :total-tokens))
              (assert.are.equal :events row.source)
              (assert.is_false row.complete?))))))))
