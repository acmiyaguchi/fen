(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local command-registry (require :fen.core.extensions.register.command))
(local prompt-registry (require :fen.core.extensions.register.prompt))
(local register-registry (require :fen.core.extensions.register))
(local tools (require :fen.core.tools))
(local json (require :fen.util.json))

;; Mocks for the child-spawning collaborators. The process mock writes a blob
;; to the FEN_JSON_OUTPUT_PATH the tool passes via :env, then returns a result
;; record shaped like run-captured's.
(fn install-mocks [run-captured-fn find-agent-fn ?list-fn ?roots-fn]
  (tset package.loaded :fen.util.process {:run-captured run-captured-fn})
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

    (it "diagnoses child timeout"
      (fn []
        (install-mocks
          (fn [_opts _yield]
            {:exit-code nil :signal 15 :timed-out? true :duration-ms 300000
             :output "partial output" :truncated? false})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "do it"})
              text (first-text r.content)]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find text "timed out: true" 1 true))
          (assert.is_truthy (string.find text "signal: 15" 1 true))
          (assert.is_true (. r.details :timed-out?))
          (assert.are.equal 15 (. r.details :signal)))))

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

    (it "errors when the task is missing"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] scout-cfg))
        (fresh)
        (let [r (execute-tool {:agent :scout})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "task" 1 true)))))))
