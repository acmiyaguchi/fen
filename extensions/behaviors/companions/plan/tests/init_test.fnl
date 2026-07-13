(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local register-registry (require :fen.core.extensions.register))
(local command-registry (require :fen.core.extensions.register.command))
(local hook-registry (require :fen.core.extensions.register.hook))
(local tool-registry (require :fen.core.extensions.register.tool))

(fn fresh []
  (test-api.reset!)
  (tset package.loaded :fen.extensions.plan nil)
  (tset package.loaded :fen.extensions.plan.state nil)
  (let [seen []
        submitted []]
    (events.on :* (fn [ev] (table.insert seen ev)))
    (let [plan (require :fen.extensions.plan)
          api (test-api.make-runtime-api :plan)
          run-state {:submit-user-turn! (fn [text opts]
                                          (table.insert submitted {:text text :opts opts})
                                          {:ok true :started? true})}]
      (plan.register api)
      (values seen submitted plan api run-state))))

(fn registered? [kind name]
  (var found? false)
  (each [_ rec (ipairs (register-registry.list kind))]
    (when (= rec.name name)
      (set found? true)))
  found?)

(fn tool-spec [name]
  (var found nil)
  (each [_ rec (ipairs (tool-registry.merged []))]
    (when (= rec.name name) (set found rec)))
  found)

(fn last-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (= ev.type type-key)
      (set found ev)))
  found)

(fn status-spec []
  (var found nil)
  (each [_ rec (ipairs (register-registry.list :status))]
    (when (= rec.name :plan)
      (set found rec)))
  found)

(fn panel-spec []
  (var found nil)
  (each [_ rec (ipairs (register-registry.list :panels))]
    (when (= rec.name :plan)
      (set found rec)))
  found)

(fn snapshot []
  (. (register-registry.collect-introspection :plan nil) :plan :state))

(describe "extensions.plan"
  (fn []
    (after_each (fn [] (test-api.reset!)))

    (it "registers command, hook, status, panel, and introspection"
      (fn []
        (fresh)
        (assert.is_true (registered? :commands :plan))
        (assert.is_true (registered? :status :plan))
        (assert.is_true (registered? :panels :plan))
        (assert.is_true (registered? :introspectors :state))
        (assert.are.equal 1 (length (register-registry.list :hooks)))))

    (it "registers a search-exposed structured plan tool without approve"
      (fn []
        (let [(_seen submitted plan _api run-state) (fresh)
              tool (tool-spec :plan)]
          (set run-state.agent {})
          (set run-state.busy? true)
          (set run-state.turn-id "active-turn")
          (assert.are.equal :search tool.exposure)
          (assert.are.same ["draft" "revise" "show" "cancel"]
                           tool.parameters.properties.action.enum)
          (let [result (tool.execute {:action "draft" :request "change it"} {:state run-state})]
            (assert.is_false result.is-error?)
            (assert.are.equal :follow-up (. submitted 1 :opts :when-busy))
            (assert.are.equal "active-turn" plan._state.active-turn-id))
          (events.emit {:type :agent-turn-complete :agent run-state.agent
                        :turn-id "other" :status :ok :result "wrong"})
          (assert.is_nil plan._state.last-plan)
          (events.emit {:type :agent-turn-complete :agent run-state.agent
                        :turn-id "active-turn" :status :ok :result "right"})
          (assert.are.equal "right" plan._state.last-plan))))

    (it "/plan submits a read-only planning prompt and captures assistant text"
      (fn []
        (let [(_seen submitted plan _api run-state) (fresh)]
          (command-registry.dispatch "/plan implement frobnicator" run-state)
          (assert.are.equal 1 (length submitted))
          (assert.are.equal :planning plan._state.mode)
          (assert.are.equal "implement frobnicator" plan._state.last-goal)
          (assert.is_truthy (string.find (. submitted 1 :text) "Enter plan mode" 1 true))
          (assert.is_truthy (string.find (. submitted 1 :text) "implement frobnicator" 1 true))
          (assert.are.equal :reject (. submitted 1 :opts :when-busy))
          (assert.is_false (. submitted 1 :opts :emit-user?))
          (events.emit {:type :agent-turn-complete
                        :status :ok
                        :result "1. Read files\n2. Edit files"
                        :message-count 2})
          (assert.are.equal :ready plan._state.mode)
          (assert.are.equal "1. Read files\n2. Edit files" plan._state.last-plan))))

    (it "captures streamed plan result from turn completion"
      (fn []
        (let [(_seen submitted plan _api run-state) (fresh)]
          (command-registry.dispatch "/plan implement frobnicator" run-state)
          (assert.are.equal 1 (length submitted))
          (assert.are.equal :planning plan._state.mode)
          (events.emit {:type :assistant-text-delta :delta "1. Read files"})
          (assert.are.equal :planning plan._state.mode)
          (events.emit {:type :assistant-stream-end :final? true})
          (assert.are.equal :planning plan._state.mode)
          (events.emit {:type :agent-turn-complete
                        :status :ok
                        :result "1. Read files\n2. Edit files"
                        :message-count 2})
          (assert.are.equal :ready plan._state.mode)
          (assert.are.equal "1. Read files\n2. Edit files" plan._state.last-plan))))

    (it "does not capture command usage text as the current plan"
      (fn []
        (let [(_seen _submitted plan _api run-state) (fresh)]
          (set plan._state.mode :planning)
          (set plan._state.last-goal "implement frobnicator")
          (command-registry.dispatch "/plan" run-state)
          (assert.are.equal :planning plan._state.mode)
          (assert.is_nil plan._state.last-plan))))

    (it "before-tool allows only read-only tools during planning"
      (fn []
        (let [(_seen _submitted plan) (fresh)]
          (set plan._state.mode :planning)
          (let [read-result (hook-registry.run-before-tool :read {} {})
                grep-result (hook-registry.run-before-tool :grep {} {})
                bash-result (hook-registry.run-before-tool :bash {} {})]
            (assert.is_false read-result.block?)
            (assert.is_false grep-result.block?)
            (assert.is_true bash-result.block?)
            (assert.is_truthy (string.find bash-result.reason "read-only" 1 true))
            (assert.are.equal "bash" plan._state.last-blocked)))))

    (it "/plan revise submits the captured plan plus guidance"
      (fn []
        (let [(_seen submitted plan _api run-state) (fresh)]
          (set plan._state.mode :ready)
          (set plan._state.last-plan "Old plan")
          (command-registry.dispatch "/plan revise add tests" run-state)
          (assert.are.equal 1 (length submitted))
          (assert.are.equal :revising plan._state.mode)
          (assert.are.equal 1 plan._state.revision-count)
          (assert.is_truthy (string.find (. submitted 1 :text) "Current plan:" 1 true))
          (assert.is_truthy (string.find (. submitted 1 :text) "Old plan" 1 true))
          (assert.is_truthy (string.find (. submitted 1 :text) "add tests" 1 true)))))

    (it "/plan approve submits the approved plan for execution and leaves plan mode"
      (fn []
        (let [(_seen submitted plan _api run-state) (fresh)]
          (set plan._state.mode :ready)
          (set plan._state.last-plan "1. Make the change")
          (command-registry.dispatch "/plan approve" run-state)
          (assert.are.equal 1 (length submitted))
          (assert.are.equal :idle plan._state.mode)
          (assert.is_truthy (string.find (. submitted 1 :text) "Approved plan:" 1 true))
          (assert.is_truthy (string.find (. submitted 1 :text) "1. Make the change" 1 true))
          (assert.is_truthy (string.find (. submitted 1 :text) "Execute this plan now." 1 true))
          (assert.are.equal :reject (. submitted 1 :opts :when-busy))))

    (it "reports missing plan on approve and revise"
      (fn []
        (let [(seen submitted) (fresh)]
          (command-registry.dispatch "/plan approve" {})
          (command-registry.dispatch "/plan revise x" {})
          (assert.are.equal 0 (length submitted))
          (assert.is_truthy (string.find (. (last-event seen :error) :error) "no captured plan" 1 true)))))

    (it "shows status, panel, and introspection while a plan is ready"
      (fn []
        (let [(_seen _submitted plan) (fresh)]
          (set plan._state.mode :ready)
          (set plan._state.last-goal "change thing")
          (set plan._state.last-plan "1. Inspect\n2. Change")
          (let [status (status-spec)
                panel (panel-spec)
                snap (snapshot)]
            (assert.are.equal "plan:ready" (. (status.render {}) :text))
            (assert.is_true (> (panel.height {:w 80}) 0))
            (let [rows (panel.render {:w 80})]
              (assert.is_true (> (length rows) 0))
              (assert.is_truthy (string.find (. rows 1 :text) "Plan mode" 1 true)))
            (assert.are.equal :ready snap.mode)
            (assert.is_true snap.has-plan?)
            (assert.are.equal "1. Inspect\n2. Change" snap.last-plan)))))

    (it "/plan panel with no argument toggles visibility without erroring"
      (fn []
        (let [(_seen _submitted plan _api run-state) (fresh)]
          (assert.is_true plan._state.visible?)
          (command-registry.dispatch "/plan panel" run-state)
          (assert.is_false plan._state.visible?)
          (command-registry.dispatch "/plan panel" run-state)
          (assert.is_true plan._state.visible?))))

    (it "a cancelled planning turn leaves plan mode without an error"
      (fn []
        (let [(_seen submitted plan _api run-state) (fresh)]
          (command-registry.dispatch "/plan implement frobnicator" run-state)
          (assert.are.equal :planning plan._state.mode)
          (events.emit {:type :agent-turn-complete
                        :status :cancelled
                        :result "[cancelled]"
                        :message-count 1})
          (assert.are.equal :idle plan._state.mode)
          (assert.is_nil plan._state.last-plan)
          (assert.is_nil plan._state.last-error))))

    (it "/plan cancel clears state and reset-conversation clears state"
      (fn []
        (let [(_seen _submitted plan _api run-state) (fresh)]
          (set plan._state.mode :ready)
          (set plan._state.last-plan "Plan")
          (command-registry.dispatch "/plan cancel" run-state)
          (assert.are.equal :idle plan._state.mode)
          (assert.is_nil plan._state.last-plan)
          (set plan._state.mode :ready)
          (set plan._state.last-plan "Plan")
          (events.emit {:type :reset-conversation})
          (assert.are.equal :idle plan._state.mode)
          (assert.is_nil plan._state.last-plan)))))))
