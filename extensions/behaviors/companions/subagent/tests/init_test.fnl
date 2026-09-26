;; Conformance kit, parent half (#516): a scripted fake child speaks wire
;; lines into the event file and reads the parent's controls, so these tests
;; drive the real subagent driver through the real channel without spawning.

(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local command-registry (require :fen.core.extensions.register.command))
(local prompt-registry (require :fen.core.extensions.register.prompt))
(local register-registry (require :fen.core.extensions.register))
(local tools (require :fen.core.tools))
(local events (require :fen.core.extensions.events))
(local wire (require :fen.util.wire))

;; ---- fake child ----

(local clock {:now 1000})
(var children [])

(fn append-line! [p line]
  (let [f (assert (io.open p :a))]
    (f:write line "\n")
    (f:close)))

(fn fake-child [opts script]
  "A child process stand-in. SCRIPT runs as a coroutine resumed once per
   handle tick; it reads controls from FEN_WIRE_CONTROL_PATH and writes wire
   events to FEN_WIRE_EVENT_PATH. A script that returns without `exit!` is a
   crash (non-zero exit, no exit event); `abort` is a kill."
  (let [env opts.env
        child {:argv opts.argv :env env :opts opts
               :controls [] :next-index 1
               :reader (wire.line-reader env.FEN_WIRE_CONTROL_PATH)
               :receiver (wire.receiver :control)
               :sender (wire.sender :event env.FEN_WIRE_RUN_ID)
               :aborted? false :code nil}]
    (fn child.raw! [line] (append-line! env.FEN_WIRE_EVENT_PATH line))
    (fn child.emit! [typ ?payload]
      (let [(line rej) (wire.next! child.sender typ ?payload)]
        (assert line (tostring (?. rej :reason)))
        (child.raw! line)))
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
        (child.emit! :control-ack {:ref msg.seq :status (or ?status :accepted)
                                   :reason ?reason})
        msg))
    (fn child.types []
      (icollect [_ c (ipairs child.controls)] c.type))
    (fn child.hang! [?advance-ms]
      ;; Never answer again; ?ADVANCE-MS fast-forwards the parent's clock.
      (while true
        (set clock.now (+ clock.now (or ?advance-ms 0)))
        (coroutine.yield)))
    (fn child.exit! [status ?code]
      (child.emit! :exit {:status status})
      (set child.code (or ?code (if (= status :done) 0 1))))
    (let [co (coroutine.create (fn [] (script child)))]
      (set child.handle
           {:abort (fn [_] (set child.aborted? true))
            :resume (fn [_]
                      (if child.aborted?
                          (values true {:exit-code nil :signal 9 :cancelled? true
                                        :duration-ms 7 :output "killed"})
                          child.code
                          (values true {:exit-code child.code :duration-ms 7
                                        :output "child output"})
                          (do (child.read!)
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

(fn answer! [child text ?usage]
  "End the current turn with TEXT, back in `ready`."
  (child.emit! :assistant-text {:text text :final? true})
  (child.emit! :llm-end {:usage (or ?usage {:input 1 :output 1 :total-tokens 2})})
  (child.emit! :turn-complete {:turn 1 :stop-reason "stop"}))

(fn result! [child text ?usage]
  (child.emit! :result {:final-text text :stop-reason "stop" :context :complete
                        :usage (or ?usage {:input 1 :output 1 :total-tokens 2})})
  (child.exit! :done))

(fn close! [child text ?usage]
  (child.expect! :close)
  (result! child text ?usage))

(fn simple [text ?usage ?middle]
  "Prompt, one turn answering TEXT, then `close` -> result -> exit done."
  (fn [child]
    (start! child)
    (prompt! child)
    (when ?middle (?middle child))
    (answer! child text ?usage)
    (close! child text ?usage)))

(fn install-mocks [script find-agent-fn ?list-fn ?roots-fn]
  (set children [])
  (set clock.now 1000)
  (tset package.loaded :fen.util.process
        {:start-captured (fn [opts]
                           (when (not script) (error "should not spawn"))
                           (when (= script :explode) (error "spawn exploded"))
                           (let [child (fake-child opts script)]
                             (table.insert children child)
                             child.handle))})
  (tset package.loaded :fen.util.clock
        {:monotonic-ms (fn [] clock.now)
         :sleep-ms (fn [ms] (set clock.now (+ clock.now ms)))})
  (tset package.loaded :fen.runtime {:binary-path (fn [] "/bin/true")})
  (tset package.loaded :fen.extensions.subagent.discover
        {:find-agent find-agent-fn
         :list (or ?list-fn (fn [] []))
         :roots (or ?roots-fn (fn [] []))}))

(fn reset-modules! []
  (each [_ m (ipairs [:fen.extensions.subagent :fen.extensions.subagent.runs
                      :fen.extensions.subagent.channel
                      :fen.extensions.subagent.state])]
    (tset package.loaded m nil)))

(fn fresh []
  (test-api.reset!)
  (reset-modules!)
  (let [subagent (require :fen.extensions.subagent)
        api (test-api.make-runtime-api :subagent)]
    (subagent.register api)
    subagent))

(fn fresh-captured []
  (reset-modules!)
  (let [api (test-api.make :subagent)
        subagent (require :fen.extensions.subagent)]
    (subagent.register api)
    api))

(fn runs [] (require :fen.extensions.subagent.runs))

(fn registered-tool [name]
  (accumulate [found nil _ rec (ipairs (tool-registry.merged [])) &until found]
    (when (= rec.name name) rec)))

(fn registered? [kind name]
  (accumulate [found? false _ rec (ipairs (register-registry.list kind)) &until found?]
    (= rec.name name)))

(fn registered-command? [name]
  (accumulate [found? false _ rec (ipairs (command-registry.list)) &until found?]
    (= rec.name name)))

(fn status-spec []
  (accumulate [found nil _ rec (ipairs (register-registry.list :status)) &until found]
    (when (= rec.name :subagent) rec)))

(fn register-presenter! [spec]
  (let [api (test-api.make-runtime-api :presenter-test)]
    (api.register :presenter spec)))

(fn snapshot []
  ((. (require :fen.extensions.subagent.runs) :snapshot)))

(fn captured-command-spec [api name]
  (accumulate [found nil _ rec (ipairs api.captured.commands) &until found]
    (when (= (. rec.spec :name) name) rec.spec)))

(fn last-assistant-text [api]
  (accumulate [text nil _ ev (ipairs api.captured.events-out)]
    (if (= ev.type :assistant-text) ev.text text)))

(fn execute-tool [args ?ctx]
  (let [out (tools.execute-call (tool-registry.merged [])
                                {:type :tool-call :id "call-1"
                                 :name :subagent :arguments args}
                                (or ?ctx {}))]
    out.result))

(fn argv-has? [argv flag val]
  (accumulate [found? false i item (ipairs (or argv [])) &until found?]
    (and (= item flag) (= (. argv (+ i 1)) val))))

(fn argv-flag? [argv flag]
  (accumulate [found? false _ item (ipairs (or argv [])) &until found?]
    (= item flag)))

(fn first-text [content]
  (let [b (. content 1)]
    (if (and b (= b.type :text)) b.text "")))

(fn contains? [s needle]
  (not= nil (string.find (tostring s) needle 1 true)))

(fn event-types [run]
  (icollect [_ ev (ipairs (or run.events []))] ev.type))

(fn has-event? [run typ]
  (accumulate [found? false _ ev (ipairs (or run.events [])) &until found?]
    (= ev.type typ)))

(fn pump-until-done! [id ?max]
  (for [_ 1 (or ?max 200) &until (not= :running (. ((. (runs) :find) id) :status))]
    (events.emit {:type :runtime-tick})))

(local scout-cfg {:name "scout" :description "Recon"
                  :model "claude-haiku-4-5" :provider nil
                  :timeout-seconds nil :tools ["read" "grep" "find" "ls"]
                  :body "You are a scout."})

(fn scout [name] (when (= name :scout) scout-cfg))

(local CANCEL-MARKER {:type :cancel-marker})

(describe "subagent tool #slow"
  (fn []
    (var saved {})
    (before_each
      (fn []
        (set saved {:process (. package.loaded :fen.util.process)
                    :clock (. package.loaded :fen.util.clock)
                    :runtime (. package.loaded :fen.runtime)
                    :discover (. package.loaded :fen.extensions.subagent.discover)})
        (let [steering (require :fen.extensions.steering.service)]
          (steering.clear-queues!))))
    (after_each
      (fn []
        (tset package.loaded :fen.util.process saved.process)
        (tset package.loaded :fen.util.clock saved.clock)
        (tset package.loaded :fen.runtime saved.runtime)
        (tset package.loaded :fen.extensions.subagent.discover saved.discover)
        (reset-modules!)))

    ;; ---- registration and discovery ----

    (it "registers the tool, commands, status, and introspection"
      (fn []
        (install-mocks nil (fn [_name] nil))
        (fresh)
        (let [tool (registered-tool :subagent)]
          (assert.is_true (. tool :parallel-safe?))
          (assert.are.equal 4 (. tool :parallel-cap)))
        (assert.is_true (registered-command? :subagents))
        (assert.is_true (registered-command? :agents))
        (assert.is_true (registered? :status :subagent))
        (assert.is_true (registered? :introspectors :state))
        (let [snap (. (register-registry.collect-introspection :subagent nil)
                      :subagent :state)]
          (assert.are.equal 0 snap.active-count)
          (assert.are.equal 0 (length snap.runs)))))

    (it "prints a clear empty agents listing with searched roots"
      (fn []
        (install-mocks nil (fn [_name] nil) (fn [] [])
                       (fn [] [{:path "./.fen/agents" :scope :project}]))
        (let [api (fresh-captured)
              cmd (captured-command-spec api :agents)]
          (cmd.handler "" {})
          (let [out (last-assistant-text api)]
            (assert.is_truthy (contains? out "No subagents discovered"))
            (assert.is_truthy (contains? out "project: ./.fen/agents"))))))

    (it "prints discovered agents with metadata"
      (fn []
        (install-mocks nil (fn [_name] nil)
                       (fn [] [{:name "scout" :description "Recon" :scope :project
                                :provider "anthropic" :model "haiku"
                                :timeout-seconds 45 :max-turns 4}]))
        (let [api (fresh-captured)
              cmd (captured-command-spec api :agents)]
          (cmd.handler "" {})
          (let [out (last-assistant-text api)]
            (assert.is_truthy (contains? out "anthropic/haiku"))
            (assert.is_truthy (contains? out "45s,turns=4"))
            (assert.is_truthy (contains? out "Recon"))))))

    (it "renders a capped subagents prompt only when the tool is visible"
      (fn []
        (let [agents (fcollect [i 1 10]
                       {:key (.. "agent" i) :description (string.rep "x" 140)
                        :scope :project})]
          (install-mocks nil (fn [_name] nil) (fn [] agents))
          (fresh)
          (assert.is_nil (prompt-registry.render {:tools []}))
          (let [rendered (prompt-registry.render {:tools [{:name :subagent}]})]
            (assert.is_truthy (contains? rendered "Available subagents"))
            (assert.is_truthy (contains? rendered "action=models"))
            (assert.is_truthy (contains? rendered "agent1"))
            (assert.is_nil (string.find rendered "agent9" 1 true))
            (assert.is_truthy (contains? rendered "2 more"))))))

    (it "lists exact models from authenticated providers before launch"
      (fn []
        (install-mocks nil (fn [_name] nil))
        (test-api.reset!)
        (reset-modules!)
        (let [subagent (require :fen.extensions.subagent)
              api (test-api.make-runtime-api :subagent)]
          (set api.models.inspect
               (fn [opts _query]
                 (assert.are.equal :refresh opts.dynamic-mode)
                 [{:name :anthropic :available? true :catalog {:status :ok}
                   :models [{:id "claude-haiku-4-5" :default? true}]}
                  {:name :openai :available? false :catalog {:status :ok}
                   :models [{:id "gpt-hidden"}]}
                  {:name :openai-codex :available? true :catalog {:status :fallback}
                   :models [{:id "gpt-5.5"}]}]))
          (subagent.register api)
          (let [r (execute-tool {:action "models"})
                out (first-text r.content)]
            (assert.are.equal 1 (. r.details :model-count))
            (assert.is_truthy (contains? out "anthropic/claude-haiku-4-5"))
            (assert.is_truthy (contains? out "catalog refresh failed"))
            (assert.is_nil (string.find out "gpt-hidden" 1 true))))))

    ;; ---- launch over the wire ----

    (it "spawns one rpc child, sends the task as the first prompt, and closes when ready"
      (fn []
        (install-mocks (simple "found it" {:input 10 :output 4 :total-tokens 14}) scout)
        (fresh)
        (let [r (execute-tool {:agent :scout :task "find the thing"})
              child (. children 1)
              run (. (snapshot) :runs 1)]
          (assert.is_false r.is-error?)
          (assert.are.equal "found it" (first-text r.content))
          (assert.are.equal "found it" run.result)
          (assert.are.equal :completed run.status)
          (assert.are.equal 1 (length children))
          (assert.are.same [:prompt :close] (child.types))
          (assert.is_truthy (contains? child.prompt "find the thing"))
          (assert.are.equal 14 (. r.details :usage :total-tokens))
          (assert.are.equal "stop" (. r.details :stop-reason))
          (assert.are.equal :done (. r.details :child-exit))
          (assert.are.equal 0 (. r.details :exit-code))
          (let [argv child.argv]
            (assert.is_true (argv-has? argv "--presenter" "rpc"))
            (assert.is_true (argv-flag? argv "--no-session"))
            (assert.is_false (argv-flag? argv "--print"))
            (assert.is_true (argv-flag? argv "--system-file"))
            (assert.is_true (argv-has? argv "--model" "claude-haiku-4-5"))
            (assert.is_true (argv-has? argv "--tools" "read,grep,find,ls")))
          (assert.are.equal "subagent-1" (. child.env :FEN_WIRE_RUN_ID))
          (assert.is_truthy (. child.env :FEN_WIRE_CONTROL_PATH))
          (assert.is_truthy (tonumber (. child.env :FEN_WIRE_DEADLINE)))
          ;; The process timeout trails the child's own deadline.
          (assert.are.equal (+ 2700 5) child.opts.timeout-seconds)
          ;; Private channel files are removed once the run settles.
          (assert.is_nil (io.open (. child.env :FEN_WIRE_CONTROL_PATH) :r)))))

    (it "keeps the control file private and written before spawn"
      (fn []
        (var mode nil)
        (var first-line nil)
        (install-mocks
          (fn [child]
            (let [p (. child.env :FEN_WIRE_CONTROL_PATH)
                  pipe (io.popen (.. "stat -c %a " p))]
              (set mode (pipe:read :*l))
              (pipe:close)
              (let [f (io.open p :r)]
                (set first-line (f:read :*l))
                (f:close)))
            ((simple "ok") child))
          scout)
        (fresh)
        (execute-tool {:agent :scout :task "check"})
        (assert.are.equal "600" mode)
        (assert.are.equal :prompt (. (wire.decode first-line :control) :type))))

    (it "runs an inline prompt without a discovered agent doc"
      (fn []
        (install-mocks (simple "inline result") (fn [_] (error "no lookup")))
        (fresh)
        (let [r (execute-tool {:prompt "You are a one-off helper." :task "say hi"
                               :model "claude-haiku-4-5" :provider "anthropic"})
              argv (. children 1 :argv)]
          (assert.is_false r.is-error?)
          (assert.are.equal "inline result" (first-text r.content))
          (assert.are.equal "inline" (. r.details :agent))
          (assert.is_true (argv-has? argv "--provider" "anthropic"))
          (assert.is_false (argv-flag? argv "--tools")))))

    (it "prefers a named agent over an inline prompt when both are given"
      (fn []
        (var looked-up nil)
        (install-mocks (simple "agent result") (fn [name] (set looked-up name) (scout name)))
        (fresh)
        (let [r (execute-tool {:agent :scout :prompt "ignored" :task "find"})]
          (assert.is_false r.is-error?)
          (assert.are.equal :scout looked-up))))

    (it "errors when task, or both agent and prompt, are missing"
      (fn []
        (install-mocks nil scout)
        (fresh)
        (assert.is_truthy (contains? (first-text (. (execute-tool {:agent :scout}) :content))
                                     "task"))
        (let [r (execute-tool {:task "do something"})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (contains? (first-text r.content) "prompt")))
        (let [r (execute-tool {:agent :nope :task "x"})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (contains? (first-text r.content) "unknown agent")))))

    ;; ---- parent tool policy ----

    (it "forwards a parent denylist to an inline child"
      (fn []
        (install-mocks (simple "ok") (fn [_] nil))
        (fresh)
        (execute-tool {:prompt "one-off" :task "say hi"}
                      {:agent {:tool-restriction {:flag "--denied-tools"
                                                  :active-names ["read"]
                                                  :restricted-names {:bash true :write true}}}})
        (let [argv (. children 1 :argv)]
          (assert.is_true (argv-has? argv "--denied-tools" "bash,write"))
          (assert.is_false (argv-flag? argv "--tools")))))

    (it "narrows a named child's allowlist by the parent's allow or deny list"
      (fn []
        (let [cfg {:name "n" :description "N" :tools ["find" "read" "bash"] :body "N."}]
          (install-mocks (simple "ok") (fn [_] cfg))
          (fresh)
          (execute-tool {:agent :n :task "inspect"}
                        {:agent {:tool-restriction {:flag "--denied-tools"
                                                    :restricted-names {:bash true :find true}}}})
          (execute-tool {:agent :n :task "inspect"}
                        {:agent {:tool-restriction {:flag "--tools"
                                                    :active-names ["read" "find"]}}})
          (assert.is_true (argv-has? (. children 1 :argv) "--tools" "read"))
          (assert.is_true (argv-has? (. children 2 :argv) "--tools" "find,read")))))

    (it "propagates a parent no-tools policy and rejects empty intersections before spawning"
      (fn []
        (install-mocks (simple "ok") scout)
        (fresh)
        (execute-tool {:agent :scout :task "inspect"}
                      {:agent {:tool-restriction {:flag "--no-tools"}}})
        (assert.is_true (argv-flag? (. children 1 :argv) "--no-tools"))
        (assert.is_false (argv-flag? (. children 1 :argv) "--tools"))
        (let [r (execute-tool {:agent :scout :task "inspect"}
                              {:agent {:tool-restriction {:flag "--tools"
                                                          :active-names ["bash"]}}})]
          (assert.is_true r.is-error?)
          (assert.are.equal :empty-intersection (. r.details :reason))
          (assert.are.equal 1 (length children))
          (assert.are.equal 0 (. (snapshot) :active-count)))))

    ;; ---- routing and cwd ----

    (it "resolves provider/model routing from inheritance, frontmatter, and call args"
      (fn []
        (let [cases [[{:name "a" :body "b"} {} "anthropic" "haiku" :inherited :inherited]
                     [{:name "a" :body "b" :model "sonnet"} {} "anthropic" "sonnet"
                      :inherited :frontmatter]
                     [{:name "a" :body "b" :provider "openai"} {} "openai" nil
                      :frontmatter :omitted-provider-override]
                     [{:name "a" :body "b" :provider "openai" :model "gpt"}
                      {:provider "sakana" :model "fugu"} "sakana" "fugu"
                      :frontmatter :frontmatter]]]
          (each [_ [cfg args provider model psrc msrc] (ipairs cases)]
            (install-mocks (simple "ok") (fn [_] cfg))
            (fresh)
            (let [call {:agent :a :task "route"}]
              (each [k v (pairs args)] (tset call k v))
              (let [r (execute-tool call {:agent {:provider-name "anthropic" :model "haiku"}})
                    argv (. children 1 :argv)]
                (assert.are.equal provider (. r.details :provider))
                (assert.are.equal model (. r.details :model))
                (assert.are.equal psrc (. r.details :provider-source))
                (assert.are.equal msrc (. r.details :model-source))
                (assert.are.equal (not= nil model) (argv-flag? argv "--model"))))))))

    (it "passes the requested cwd through spawn, PWD, prompt context, and details"
      (fn []
        (install-mocks (simple "ok") scout)
        (fresh)
        (let [r (execute-tool {:agent :scout :task "look here" :cwd "/tmp"})
              child (. children 1)]
          (assert.are.equal "/tmp" child.opts.cwd)
          (assert.are.equal "/tmp" (. child.env :PWD))
          (assert.is_truthy (contains? child.prompt "Child PWD: /tmp"))
          (assert.are.equal "/tmp" (. r.details :cwd))
          (let [bad (execute-tool {:agent :scout :task "x" :cwd "/nonexistent/dir"})]
            (assert.is_true bad.is-error?)))))

    (it "caps a per-call timeout by agent policy and forwards it as the child deadline"
      (fn []
        (install-mocks (simple "ok")
                       (fn [_] {:name "t" :body "b" :timeout-seconds 60}))
        (fresh)
        (execute-tool {:agent :t :task "x" :timeout-seconds 30})
        (execute-tool {:agent :t :task "x" :timeout-seconds 600})
        (assert.are.equal 35 (. children 1 :opts :timeout-seconds))
        (assert.are.equal 65 (. children 2 :opts :timeout-seconds))
        (let [deadline (tonumber (. children 1 :env :FEN_WIRE_DEADLINE))]
          (assert.is_true (<= (- deadline (os.time)) 30)))))

    ;; ---- live events ----

    (it "records forwarded child events, counters, and artifacts in run state"
      (fn []
        (var status-during nil)
        (install-mocks
          (simple "done" nil
                  (fn [child]
                    (child.emit! :tool-call {:name "grep" :summary "search files"
                                             :arguments {:pattern "x"}})
                    (child.emit! :tool-result {:name "edit" :is-error? false
                                               :summary "edited a.fnl"})
                    (coroutine.yield)
                    (coroutine.yield)
                    (set status-during ((. (status-spec) :render) {}))))
          scout)
        (fresh)
        (let [r (execute-tool {:agent :scout :task "inspect"})
              run (. (snapshot) :runs 1)]
          (assert.are.equal "subagent:1 running" status-during.text)
          (assert.are.same [:subagent-start :agent-started :tool-call :tool-result
                            :assistant-text :llm-end :subagent-done]
                           (event-types run))
          (assert.are.equal 1 (. r.details :tool-call-count))
          (assert.are.equal 1 (. r.details :turn-count))
          (assert.are.equal :tool-result run.first-artifact-kind)
          (assert.is_nil ((. (status-spec) :render) {}))
          ;; The wire envelope is not retained on display events.
          (let [ev (. run.events 3)]
            (assert.is_nil ev.v)
            (assert.is_nil ev.run)
            (assert.are.equal "search files" ev.summary)))))

    (it "records malformed child output and still completes"
      (fn []
        (install-mocks
          (simple "done" nil
                  (fn [child]
                    (child.raw! "not json at all")
                    ;; A valid envelope whose tool-call payload lacks `name`.
                    (set child.sender.seq (+ child.sender.seq 1))
                    (child.raw! (.. "{\"v\":1,\"seq\":" child.sender.seq
                                    ",\"type\":\"tool-call\",\"run\":\""
                                    (. child.env :FEN_WIRE_RUN_ID) "\"}"))))
          scout)
        (fresh)
        (let [r (execute-tool {:agent :scout :task "inspect"})]
          (assert.is_false r.is-error?)
          (assert.are.equal "done" (first-text r.content))
          (assert.are.equal 2 (. r.details :event-error-count)))))

    (it "fails a child that crashes without an exit event"
      (fn []
        (install-mocks
          (fn [child]
            (start! child)
            (prompt! child)
            (child.emit! :tool-call {:name "read" :arguments {:path "a"}})
            (child.emit! :assistant-text {:text "half an answer" :final? false}))
          scout)
        (fresh)
        (let [r (execute-tool {:agent :scout :task "inspect"})
              text (first-text r.content)]
          (assert.is_true r.is-error?)
          (assert.are.equal :failed (. (snapshot) :runs 1 :status))
          (assert.are.equal 3 (. r.details :exit-code))
          (assert.is_nil (. r.details :child-exit))
          (assert.is_truthy (contains? text "Subagent failed."))
          (assert.is_truthy (contains? text "Child message:\nhalf an answer"))
          (assert.is_truthy (contains? text "Latest child progress")))))

    (it "fails and kills a child that speaks another wire version"
      (fn []
        (install-mocks
          (fn [child]
            (child.raw! (.. "{\"v\":2,\"seq\":1,\"type\":\"ready\",\"run\":\""
                            (. child.env :FEN_WIRE_RUN_ID) "\"}"))
            (child.hang!))
          scout)
        (fresh)
        (let [r (execute-tool {:agent :scout :task "inspect"})
              child (. children 1)]
          (assert.is_true r.is-error?)
          (assert.are.equal :failed (. (snapshot) :runs 1 :status))
          (assert.is_truthy (contains? (. r.details :child-error) "wire version 2"))
          (assert.are.same [:prompt :cancel] (child.types))
          (assert.is_true child.aborted?))))

    (it "reports a child exit status and partial progress on timeout"
      (fn []
        (install-mocks
          (fn [child]
            (start! child)
            (prompt! child)
            (child.emit! :tool-call {:name "grep" :arguments {:pattern "needle"}})
            (child.emit! :llm-end {:usage {:input 30 :output 4 :total-tokens 34}})
            (child.emit! :turn-complete {:turn 1 :stop-reason "aborted"})
            (child.exit! :timed-out))
          scout)
        (fresh)
        (let [r (execute-tool {:agent :scout :task "slow" :timeout-seconds 5})
              text (first-text r.content)]
          (assert.is_true r.is-error?)
          (assert.are.equal :timed-out (. (snapshot) :runs 1 :status))
          (assert.is_true (. r.details :timed-out?))
          (assert.is_true (. r.details :partial-progress?))
          (assert.is_truthy (contains? text "tool-call grep"))
          (assert.is_truthy (contains? text "Next action"))
          ;; Completed-turn usage survives a run with no `result`.
          (assert.are.equal 34 (. r.details :usage :total-tokens))
          (assert.are.equal :events (. r.details :usage-source))
          (assert.is_false (. r.details :usage-complete?)))))

    (it "takes usage from the result without double counting per-turn events"
      (fn []
        (install-mocks
          (fn [child]
            (start! child)
            (prompt! child)
            (child.emit! :llm-end {:usage {:input 40 :output 5 :total-tokens 45}})
            (answer! child "done" {:input 42 :output 2 :total-tokens 44})
            (close! child "done" {:input 82 :output 7 :total-tokens 89}))
          scout)
        (fresh)
        (let [r (execute-tool {:agent :scout :task "count"})]
          (assert.are.equal 89 (. r.details :usage :total-tokens))
          (assert.are.equal :final-result (. r.details :usage-source))
          (assert.is_true (. r.details :usage-complete?))
          (assert.are.equal 2 (. r.details :usage-turns)))))

    (it "distinguishes empty successful final text"
      (fn []
        (install-mocks (simple "") scout)
        (fresh)
        (let [r (execute-tool {:agent :scout :task "x"})]
          (assert.is_false r.is-error?)
          (assert.is_truthy (contains? (first-text r.content)
                                       "Subagent completed with empty final text.")))))

    ;; ---- steering ----

    (it "sends a mid-run steer to the live child without restarting it"
      (fn []
        (install-mocks
          (fn [child]
            (start! child)
            (prompt! child)
            (command-registry.dispatch "/subagents steer subagent-1 focus on tests"
                                       {:busy? true})
            (let [steer (child.expect! :steer)]
              (child.emit! :steering-injected {:text steer.text :ref steer.seq}))
            (answer! child "steered")
            (close! child "steered"))
          scout)
        (fresh-captured)
        (let [r (execute-tool {:agent :scout :task "look"})
              run (. (snapshot) :runs 1)
              child (. children 1)]
          (assert.is_false r.is-error?)
          (assert.are.equal "steered" (first-text r.content))
          (assert.are.equal 1 (length children))
          (assert.are.same [:prompt :steer :close] (child.types))
          (assert.are.equal "focus on tests" (. child.controls 2 :text))
          (assert.are.equal 1 (. r.details :steering-count))
          (assert.is_true (has-event? run :steering-injected)))))

    (it "records a steer the child rejects and keeps running"
      (fn []
        (install-mocks
          (fn [child]
            (start! child)
            (prompt! child)
            (answer! child "answer")
            ;; The parent closes; a steer arriving after close is rejected.
            (child.expect! :close)
            ((. (runs) :request-steer!) "subagent-1" "too late" :agent)
            (child.expect! :steer :rejected "run is closing")
            (result! child "answer"))
          scout)
        (fresh)
        (let [r (execute-tool {:agent :scout :task "look"})
              run (. (snapshot) :runs 1)]
          (assert.is_false r.is-error?)
          (assert.are.equal "answer" (first-text r.content))
          (assert.is_true (has-event? run :steering-rejected)))))

    (it "queues steering through the agentic action and rejects inactive runs"
      (fn []
        (install-mocks nil scout)
        (fresh)
        (let [run ((. (runs) :start!) {:agent "scout" :task "inspect" :cwd "/tmp"})
              ok (execute-tool {:action "steer" :run-id run.id :note "focus"})]
          (assert.is_false ok.is-error?)
          (assert.are.equal 1 (length ok.details.run.pending-steering))
          ((. (runs) :finish!) run.id :completed {})
          (assert.is_true (. (execute-tool {:action "steer" :run-id run.id :note "x"})
                             :is-error?)))))

    ;; ---- budgets ----

    (it "finalizes in the same conversation when a tool budget is reached"
      (fn []
        (install-mocks
          (fn [child]
            (start! child)
            (prompt! child)
            (child.emit! :tool-call {:name "read" :arguments {:path "a"}})
            (let [fin (child.expect! :finalize)]
              (set child.note fin.note))
            (child.emit! :turn-complete {:turn 1 :stop-reason "aborted"})
            (child.emit! :turn-started {:turn 2})
            (child.emit! :assistant-text {:text "findings" :final? true})
            (child.emit! :turn-complete {:turn 2 :stop-reason "stop"})
            (result! child "findings"))
          scout)
        (fresh)
        (let [r (execute-tool {:agent :scout :task "review" :max-tool-calls 1})
              child (. children 1)
              run (. (snapshot) :runs 1)]
          (assert.is_false r.is-error?)
          (assert.are.equal "findings" (first-text r.content))
          (assert.are.equal 1 (length children))
          (assert.are.same [:prompt :finalize] (child.types))
          (assert.is_truthy (contains? child.note "Investigation budget reached"))
          (assert.is_truthy (contains? child.note "max-tool-calls 1 reached"))
          (assert.is_true (. r.details :budget-finalization-requested?))
          (assert.is_true (has-event? run :budget-finalization))
          (assert.are.equal :done run.display-status))))

    (it "finalizes on max-turns and on an artifact checkpoint with no artifact"
      (fn []
        (fn finalize-script [child]
          (start! child)
          (prompt! child)
          (child.emit! :llm-end {:usage {:input 1 :output 1}})
          (child.expect! :finalize)
          (child.emit! :assistant-text {:text "final" :final? true})
          (result! child "final"))
        (install-mocks finalize-script scout)
        (fresh)
        (let [r (execute-tool {:agent :scout :task "t" :max-turns 1})]
          (assert.are.equal "max-turns 1 reached" (. r.details :budget-finalization-reason)))
        (let [real-time os.time
              clock-s {:now (real-time)}]
          ;; The checkpoint uses wall-clock seconds: each read advances one.
          (set os.time (fn [?t]
                         (if ?t
                             (real-time ?t)
                             (do (set clock-s.now (+ clock-s.now 1))
                                 clock-s.now))))
          (let [(ok? r) (pcall execute-tool {:agent :scout :task "t"
                                             :artifact-checkpoint-seconds 10})]
            (set os.time real-time)
            (assert.is_true ok? r)
            (assert.is_truthy (contains? (. r.details :budget-finalization-reason)
                                         "no artifact within checkpoint"))))))

    (it "does not finalize once the task turn is done and closes instead"
      (fn []
        (install-mocks
          (fn [child]
            (start! child)
            (prompt! child)
            (child.emit! :tool-call {:name "read" :arguments {:path "a"}})
            (child.emit! :assistant-text {:text "answer" :final? false})
            (child.emit! :turn-complete {:turn 1 :stop-reason "stop"})
            (close! child "answer"))
          scout)
        (fresh)
        (let [r (execute-tool {:agent :scout :task "t" :max-tool-calls 1})]
          (assert.is_false r.is-error?)
          (assert.are.same [:prompt :close] ((. children 1 :types))))))

    (it "cancels then kills a child that ignores finalize past the grace window"
      (fn []
        (install-mocks
          (fn [child]
            (start! child)
            (prompt! child)
            (child.emit! :tool-call {:name "read" :arguments {:path "a"}})
            (child.expect! :finalize)
            (child.hang! 10000))
          scout)
        (fresh)
        (let [r (execute-tool {:agent :scout :task "t" :max-tool-calls 1})
              child (. children 1)]
          (assert.is_true r.is-error?)
          (assert.are.same [:prompt :finalize :cancel] (child.types))
          (assert.is_true child.aborted?)
          (assert.are.equal :cancelled (. (snapshot) :runs 1 :status))
          (assert.is_true (. r.details :budget-finalization-requested?)))))

    ;; ---- cancellation ----

    (it "cancels a blocking run in every non-terminal state"
      (fn []
        (let [cases
              {:starting (fn [child] (child.emit! :agent-started {}))
               :ready (fn [child]
                        (start! child)
                        (prompt! child)
                        (child.emit! :assistant-text {:text "partial" :final? false}))
               :running (fn [child]
                          (start! child)
                          (prompt! child)
                          (child.emit! :tool-call {:name "bash" :arguments {:cmd "sleep 9"}}))
               :finalizing (fn [child]
                             (start! child)
                             (prompt! child)
                             (child.emit! :tool-call {:name "read" :arguments {:path "a"}})
                             (child.expect! :finalize))}]
          (each [state setup (pairs cases)]
            (install-mocks
              (fn [child]
                (setup child)
                (tset (. ((. (runs) :record) "subagent-1") :job) :cancel-requested? true)
                (while (not= :cancel (?. child.controls (length child.controls) :type))
                  (coroutine.yield))
                (child.emit! :control-ack {:ref (. child.controls (length child.controls) :seq)
                                           :status :accepted})
                (child.exit! :cancelled))
              scout)
            (fresh)
            (let [r (execute-tool {:agent :scout :task state :max-tool-calls 1})
                  child (. children 1)
                  sent (child.types)]
              (assert.is_true r.is-error? state)
              (assert.are.equal :cancelled (. (snapshot) :runs 1 :status) state)
              (assert.are.equal :cancel (. sent (length sent)) state)
              (assert.is_false child.aborted? state)
              (assert.are.equal :cancelled (. r.details :child-exit) state))))))

    (it "cancels and reaps the child when the parent turn is cancelled, then rethrows"
      (fn []
        (install-mocks
          (fn [child]
            (start! child)
            (prompt! child)
            (child.emit! :tool-call {:name "bash" :arguments {:cmd "sleep 60"}})
            ;; Mid-tool: the child never reaches a yield, so it ignores cancel.
            (child.hang!))
          scout)
        (fresh)
        (let [tool (registered-tool :subagent)
              yields {:n 0}
              (ok? err) (pcall tool.execute {:agent :scout :task "work"} {}
                               (fn []
                                 (set yields.n (+ yields.n 1))
                                 (when (> yields.n 3) (error CANCEL-MARKER))))
              child (. children 1)]
          (assert.is_false ok?)
          (assert.are.equal CANCEL-MARKER err)
          (assert.are.same [:prompt :cancel] (child.types))
          (assert.is_true child.aborted?)
          (let [run (. (snapshot) :runs 1)]
            (assert.are.equal :cancelled run.status)
            (assert.are.equal 0 (. (snapshot) :active-count))))))

    (it "lets /subagents cancel request current-turn and run cancellation"
      (fn []
        (var turn-state nil)
        (install-mocks
          (fn [child]
            (start! child)
            (prompt! child)
            (set turn-state {:busy? true :cancel-requested? false})
            (command-registry.dispatch "/subagents cancel" turn-state)
            (child.expect! :cancel)
            (child.exit! :cancelled))
          scout)
        (let [api (fresh-captured)
              r (execute-tool {:agent :scout :task "cancel me"})]
          (assert.is_true r.is-error?)
          (assert.is_true turn-state.cancel-requested?)
          (assert.is_truthy (contains? (last-assistant-text api) "Requested cancellation")))))

    ;; ---- background runs ----

    (it "pumps a background run on runtime ticks and queues its completion"
      (fn []
        (var ticks 0)
        (install-mocks
          (simple "background finding" nil
                  (fn [child]
                    (child.emit! :tool-result {:name "grep" :is-error? false
                                               :summary "matching files"})
                    (while (< ticks 3) (coroutine.yield))))
          scout)
        (let [api (fresh-captured)
              steering (require :fen.extensions.steering.service)
              tool (registered-tool :subagent)
              r (tool.execute {:agent :scout :task "inspect it" :background true} {})]
          (assert.is_false r.is-error?)
          (assert.are.equal "subagent-1" (. r.details :run-id))
          (for [_ 1 3]
            (set ticks (+ ticks 1))
            (events.emit {:type :runtime-tick}))
          (assert.is_truthy (contains? (. children 1 :prompt) "Background authority"))
          (command-registry.dispatch "/subagents show subagent-1" {})
          (let [shown (last-assistant-text api)]
            (assert.is_truthy (contains? shown "Live activity:"))
            (assert.is_truthy (contains? shown "tool-result: matching files")))
          (pump-until-done! "subagent-1")
          (let [snap (snapshot)
                run (. snap.runs 1)
                queued (steering.queue-snapshot)]
            (assert.are.equal 0 snap.active-count)
            (assert.are.equal :completed run.status)
            (assert.are.equal "background finding" run.result)
            (assert.is_nil run.job)
            (assert.are.equal 1 (length queued.follow-up))
            (assert.is_truthy (contains? (. queued.follow-up 1) "background finding"))))))

    (it "steers, cancels by id, waits for, and retries detached runs"
      (fn []
        (install-mocks
          (fn [child]
            (start! child)
            (prompt! child)
            (if (= (length children) 1)
                (do
                  (let [steer (child.expect! :steer)]
                    (child.emit! :steering-injected {:text steer.text :ref steer.seq}))
                  (child.expect! :cancel)
                  (child.exit! :cancelled))
                (do (answer! child "retried")
                    (close! child "retried"))))
          scout)
        (let [api (fresh-captured)
              tool (registered-tool :subagent)
              launched (tool.execute {:agent :scout :task "inspect" :background true} {})
              id launched.details.run-id]
          (assert.is_false (. (tool.execute {:action "steer" :run-id id :note "focus"} {})
                              :is-error?))
          (events.emit {:type :runtime-tick})
          (events.emit {:type :runtime-tick})
          (command-registry.dispatch (.. "/subagents cancel " id) {})
          (assert.is_truthy (contains? (last-assistant-text api) "Requested cancellation"))
          (pump-until-done! id)
          (assert.are.equal :cancelled (. (snapshot) :runs 1 :status))
          (assert.are.same [:prompt :steer :cancel] ((. children 1 :types)))
          (let [retried (tool.execute {:action "retry" :run-id id} {})
                waited (tool.execute {:action "wait" :run-id retried.details.run-id} {})]
            (assert.is_false retried.is-error?)
            (assert.are.equal id retried.details.retry-of)
            (assert.are.equal :completed waited.details.run.status)
            (assert.are.equal id waited.details.run.retry-of)))))

    (it "cancels detached runs on reload, /new, reset, and the cancel action"
      (fn []
        (fn cancellable [child]
          (start! child)
          (prompt! child)
          (child.expect! :cancel)
          (child.exit! :cancelled))
        (install-mocks cancellable scout)
        (fresh)
        (let [steering (require :fen.extensions.steering.service)]
          ;; Reload: registering the new behavior reaps the old jobs.
          ((. (registered-tool :subagent) :execute)
           {:agent :scout :task "one" :background true} {})
          (tset package.loaded :fen.extensions.subagent nil)
          ((. (require :fen.extensions.subagent) :register)
           (test-api.make-runtime-api :subagent))
          (assert.are.equal :cancelled (. ((. (runs) :find) "subagent-1") :status))
          ;; /new cancels quietly and clears history; a resume does not.
          (steering.clear-queues!)
          (let [tool (registered-tool :subagent)]
            (tool.execute {:agent :scout :task "two" :background true} {})
            (events.emit {:type :reset-conversation :reason :resume})
            (assert.are.equal 1 (. (snapshot) :active-count))
            (events.emit {:type :reset-conversation :reason :new})
            (assert.are.equal 0 (. (snapshot) :active-count))
            (assert.are.equal 0 (length (. (snapshot) :runs)))
            (assert.are.equal 0 (length (. (steering.queue-snapshot) :follow-up)))
            (tool.execute {:agent :scout :task "three" :background true} {})
            (let [reset (tool.execute {:action "reset"} {})]
              (assert.are.equal 1 reset.details.cancelled)
              (assert.are.equal 0 (length (. (snapshot) :runs))))
            (let [launched (tool.execute {:agent :scout :task "four" :background true} {})
                  cancelled (tool.execute {:action "cancel"
                                           :run-id launched.details.run-id} {})]
              (assert.is_false cancelled.is-error?)
              (assert.are.equal :cancelled cancelled.details.run.status))
            (assert.are.equal 4 (length children))
            (each [_ child (ipairs children)]
              (assert.are.equal :cancel (. (child.types) 2))
              (assert.is_false child.aborted?))))))

    (it "gates background runs on a presenter with idle ticks"
      (fn []
        (install-mocks (simple "ok") scout)
        (fresh)
        (register-presenter! {:name :stdio :active? true :run (fn [_ctx] nil)})
        (register-presenter! {:name :tui :active? true :idle-ticks? true
                              :run (fn [_ctx] nil)})
        (let [tool (registered-tool :subagent)
              rejected (tool.execute {:agent :scout :task "i" :background true}
                                     {:state {:opts {:presenter :stdio}}})
              allowed (tool.execute {:agent :scout :task "i" :background true}
                                    {:state {:opts {:presenter :tui}}})]
          (assert.is_true rejected.is-error?)
          (assert.is_truthy (contains? (first-text rejected.content) "ticking presenter"))
          (assert.is_false allowed.is-error?)
          (assert.are.equal 1 (length children)))))

    (it "reports a background launch failure without queuing a completion"
      (fn []
        (install-mocks :explode scout)
        (fresh)
        (let [steering (require :fen.extensions.steering.service)
              r ((. (registered-tool :subagent) :execute)
                 {:agent :scout :task "inspect" :background true} {})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (contains? (first-text r.content) "spawn exploded"))
          (assert.are.equal 0 (. (snapshot) :active-count))
          (assert.are.equal 0 (length (. (steering.queue-snapshot) :follow-up))))))

    (it "marks orphaned background runs failed without touching blocking runs"
      (fn []
        (install-mocks nil scout)
        (fresh)
        (let [r (runs)
              bg (r.start! {:agent "scout" :task "bg" :cwd "/tmp" :background? true})
              blocking (r.start! {:agent "scout" :task "blocking" :cwd "/tmp"})]
          (assert.are.equal 1 (r.reconcile-background!))
          (assert.are.equal :failed (. (r.find bg.id) :status))
          (assert.are.equal :running (. (r.find blocking.id) :status)))))

    ;; ---- run records, listings, and usage views ----

    (it "keeps long-running active runs visible past the recent history window"
      (fn []
        (install-mocks nil scout)
        (let [api (fresh-captured)
              r (runs)
              active (r.start! {:agent :scout :task "long running" :cwd "/tmp"})]
          (for [i 1 25]
            (let [done (r.start! {:agent :scout :task (.. "finished " i) :cwd "/tmp"})]
              (r.finish! done.id :completed {:duration-ms i})))
          (assert.are.equal active.id (. (snapshot) :active-runs 1 :id))
          (command-registry.dispatch "/subagents" {:busy? true})
          (assert.is_truthy (contains? (last-assistant-text api) active.id)))))

    (it "supports list, show, remove, and clear management actions"
      (fn []
        (install-mocks nil scout)
        (fresh)
        (let [r (runs)
              run (r.start! {:agent "scout" :task "inspect" :cwd "/tmp"})]
          (r.append-event! run.id {:type :tool-call :name :read :summary "state.fnl"})
          (r.finish! run.id :completed {:result "final finding"
                                        :output-tail "child stderr"})
          (let [listed (execute-tool {:action "list"})
                shown (execute-tool {:action "show" :run-id run.id})
                text (first-text shown.content)]
            (assert.is_truthy (contains? (first-text listed.content) run.id))
            (assert.is_truthy (contains? text "status: done"))
            (assert.is_truthy (contains? text "tool-call: state.fnl"))
            (assert.is_truthy (contains? text "Result:\nfinal finding"))
            (assert.is_truthy (contains? text "Process output tail:\nchild stderr")))
          (assert.is_false (. (execute-tool {:action "remove" :run-id run.id}) :is-error?))
          (let [another (r.start! {:agent "scout" :task "another" :cwd "/tmp"})]
            (assert.is_true (. (execute-tool {:action "clear"}) :is-error?))
            (r.finish! another.id :completed {}))
          (assert.is_false (. (execute-tool {:action "clear"}) :is-error?))
          (assert.are.equal 0 (length (. (snapshot) :runs)))
          (assert.are_not.equal run.id (. (r.start! {:agent "s" :task "n"}) :id)))))

    (it "shows parent-facing outcomes for budget-limited runs"
      (fn []
        (install-mocks nil scout)
        (fresh)
        (let [r (runs)
              failed (r.start! {:agent "s" :task "a"})
              done (r.start! {:agent "s" :task "b"})
              limited (r.start! {:agent "s" :task "c"})]
          (each [_ run (ipairs [failed done limited])]
            (set run.budget-limited? true))
          (set done.final-answer-produced? true)
          (r.finish! failed.id :failed {})
          (r.finish! done.id :completed {})
          (r.finish! limited.id :completed {})
          (assert.are.same [:failed :done :budget-limited]
                           (icollect [_ run (ipairs (. (snapshot) :runs))]
                             run.display-status)))))

    (it "warns on the third identical no-artifact timeout"
      (fn []
        (install-mocks
          (fn [child]
            (start! child)
            (prompt! child)
            (child.exit! :timed-out))
          (fn [_] {:name "reviewer" :body "Review." :timeout-seconds 5}))
        (let [api (fresh-captured)]
          (execute-tool {:agent :reviewer :task "review  diff"})
          (execute-tool {:agent :reviewer :task "review diff"})
          (let [r (execute-tool {:agent :reviewer :task "review diff"})]
            (assert.are.equal 3 (. r.details :repeated-timeout-warning :count))
            (assert.is_truthy (contains? (first-text r.content)
                                         "Attempt 3 after 2 retained identical timeouts"))
            (command-registry.dispatch "/subagents" {})
            (assert.is_truthy (contains? (last-assistant-text api)
                                         "Repeated timeout warnings"))))))

    (it "surfaces repeated inspection warnings"
      (fn []
        (install-mocks
          (fn [child]
            (start! child)
            (prompt! child)
            (for [_ 1 3]
              (child.emit! :tool-call {:name "grep"
                                       :arguments {:path "src" :pattern "needle"}}))
            (child.exit! :timed-out))
          scout)
        (fresh)
        (let [r (execute-tool {:agent :scout :task "review"})]
          (assert.are.equal 1 (. r.details :repeated-inspection-warning-count))
          (assert.is_truthy (contains? (first-text r.content) "repeated inspection")))))

    (it "renders usage tables and structured usage rows"
      (fn []
        (install-mocks nil scout)
        (let [api (fresh-captured)
              r (runs)
              a (r.start! {:agent "scout" :task "one"})
              b (r.start! {:agent "scout" :task "two"})]
          (r.accumulate-usage! a.id {:input 80 :output 5 :total-tokens 85})
          (r.finish! a.id :completed {:provider "sakana" :model "fugu"
                                      :usage {:input 80 :output 5 :total-tokens 85}})
          (r.accumulate-usage! b.id {:input 12 :output 4 :total-tokens 16})
          (r.finish! b.id :timed-out {:timed-out? true})
          (command-registry.dispatch "/subagents usage" {})
          (let [out (last-assistant-text api)]
            (assert.is_truthy (contains? out "TOTAL"))
            (assert.is_truthy (contains? out "sakana / fugu / completed")))
          (let [rows (. (execute-tool {:action "usage"}) :details :runs)]
            (assert.are.equal 16 (. rows 2 :usage :total-tokens))
            (assert.are.equal :events (. rows 2 :source))
            (assert.is_false (. rows 2 :complete?)))
          ;; Snapshots never leak live tables.
          (tset (. (r.snapshot) :runs 1 :details :usage) :total-tokens 99999)
          (assert.are.equal 85 (. (r.snapshot) :runs 1 :details :usage :total-tokens)))))))
