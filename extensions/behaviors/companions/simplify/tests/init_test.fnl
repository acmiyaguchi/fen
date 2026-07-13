(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local register-registry (require :fen.core.extensions.register))
(local command-registry (require :fen.core.extensions.register.command))
(local frontmatter (require :fen.util.frontmatter))
(local tool-registry (require :fen.core.extensions.register.tool))

;; Keep a handle on the real process module so we can restore it after stubbing.
(local real-process (require :fen.util.process))

;; Mutable git fixture the process stub reads at call time, so tests can vary the
;; diff without re-requiring the module under test.
(local git {:tracked "src/a.fnl\nsrc/b.fnl\n" :untracked "" :ok? true})

(local process-stub
  {:run-captured (fn [opts _yield]
                   (let [cmd (or (?. opts :cmd) "")]
                     (if (not git.ok?)
                         {:exit-code 1 :output ""}
                         (string.find cmd "ls-files" 1 true)
                         {:exit-code 0 :output git.untracked}
                         {:exit-code 0 :output git.tracked})))})

(fn fresh []
  (test-api.reset!)
  (tset package.loaded :fen.extensions.simplify nil)
  (tset package.loaded :fen.extensions.simplify.state nil)
  (tset package.loaded :fen.util.process process-stub)
  (let [seen []
        submitted []]
    (events.on :* (fn [ev] (table.insert seen ev)))
    (let [simplify (require :fen.extensions.simplify)
          api (test-api.make-runtime-api :simplify)
          run-state {:submit-user-turn! (fn [text opts]
                                          (table.insert submitted {:text text :opts opts})
                                          {:ok true :started? true})}]
      (simplify.register api)
      (values seen submitted simplify api run-state))))

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
    (when (= rec.name :simplify)
      (set found rec)))
  found)

(fn snapshot []
  (. (register-registry.collect-introspection :simplify nil) :simplify :state))

(describe "extensions.simplify"
  (fn []
    (after_each (fn []
                  (test-api.reset!)
                  (tset package.loaded :fen.util.process real-process)
                  (set git.ok? true)
                  (set git.tracked "src/a.fnl\nsrc/b.fnl\n")
                  (set git.untracked "")))

    (it "registers command, status, and introspection (no hook or panel)"
      (fn []
        (fresh)
        (assert.is_true (registered? :commands :simplify))
        (assert.is_true (registered? :status :simplify))
        (assert.is_true (registered? :introspectors :state))
        (assert.are.equal 0 (length (register-registry.list :hooks)))
        (assert.are.equal 0 (length (register-registry.list :panels)))))

    (it "registers a search-exposed simplify tool that queues a correlated follow-up"
      (fn []
        (let [(_seen submitted simplify _api run-state) (fresh)
              tool (tool-spec :simplify)]
          (set run-state.agent {})
          (set run-state.busy? true)
          (set run-state.turn-id "active-turn")
          (let [result (tool.execute {:base "main"} {:state run-state})]
            (assert.are.equal :search tool.exposure)
            (assert.is_false result.is-error?)
            (assert.are.equal :text (. result.content 1 :type))
            (assert.are.equal :follow-up (. submitted 1 :opts :when-busy))
            (assert.are.equal "active-turn" simplify._state.active-turn-id))
          (events.emit {:type :agent-turn-complete :agent run-state.agent
                        :turn-id "other" :status :ok :result "wrong"})
          (assert.are.equal :running simplify._state.status)
          (events.emit {:type :agent-turn-complete :agent run-state.agent
                        :turn-id "active-turn" :status :ok :result "done"})
          (assert.are.equal "done" simplify._state.last-summary))))

    (it "/simplify submits a quality-cleanup turn over the changed files"
      (fn []
        (let [(_seen submitted simplify _api run-state) (fresh)]
          (command-registry.dispatch "/simplify" run-state)
          (assert.are.equal 1 (length submitted))
          (assert.are.equal :running simplify._state.status)
          (let [text (. submitted 1 :text)]
            (assert.is_truthy (string.find text "reuse, simplification, efficiency, and altitude" 1 true))
            (assert.is_truthy (string.find text "subagent" 1 true))
            (assert.is_truthy (string.find text "src/a.fnl" 1 true))
            (assert.is_truthy (string.find text "uncommitted working-tree changes" 1 true)))
          (assert.are.equal :reject (. submitted 1 :opts :when-busy))
          (assert.is_false (. submitted 1 :opts :emit-user?))
          (events.emit {:type :agent-turn-complete :status :ok :result "Applied 2 cleanups."})
          (assert.are.equal :idle simplify._state.status)
          (assert.are.equal "Applied 2 cleanups." simplify._state.last-summary))))

    (it "/simplify <ref> scopes to changes since the ref"
      (fn []
        (let [(_seen submitted simplify _api run-state) (fresh)]
          (set git.tracked "lib/c.fnl\n")
          (command-registry.dispatch "/simplify main" run-state)
          (assert.are.equal 1 (length submitted))
          (assert.are.equal "main" simplify._state.last-base)
          (let [text (. submitted 1 :text)]
            (assert.is_truthy (string.find text "changes since main" 1 true))
            (assert.is_truthy (string.find text "lib/c.fnl" 1 true))))))

    (it "/simplify with no changed files does not submit a turn"
      (fn []
        (let [(seen submitted simplify _api run-state) (fresh)]
          (set git.tracked "")
          (set git.untracked "")
          (command-registry.dispatch "/simplify" run-state)
          (assert.are.equal 0 (length submitted))
          (assert.are.equal :idle simplify._state.status)
          (assert.is_truthy (string.find (. (last-event seen :info) :text) "no changed files" 1 true)))))

    (it "/simplify show reprints the last summary without submitting"
      (fn []
        (let [(seen submitted simplify _api run-state) (fresh)]
          (set simplify._state.last-summary "Earlier summary")
          (command-registry.dispatch "/simplify show" run-state)
          (assert.are.equal 0 (length submitted))
          (assert.is_truthy (string.find (. (last-event seen :assistant-text) :text) "Earlier summary" 1 true)))))

    (it "rejects a second /simplify while one is already running"
      (fn []
        (let [(seen submitted simplify _api run-state) (fresh)]
          (command-registry.dispatch "/simplify" run-state)
          (assert.are.equal 1 (length submitted))
          (command-registry.dispatch "/simplify" run-state)
          (assert.are.equal 1 (length submitted))
          (assert.is_truthy (string.find (. (last-event seen :info) :text) "already running" 1 true)))))

    (it "shows a running status and snapshot while a simplify turn is active"
      (fn []
        (let [(_seen _submitted simplify) (fresh)]
          (set simplify._state.status :running)
          (set simplify._state.last-summary "S")
          (let [status (status-spec)
                snap (snapshot)]
            (assert.are.equal "simplify:running" (. (status.render {}) :text))
            (assert.are.equal :running snap.status)
            (assert.is_true snap.running?)
            (assert.is_true snap.has-summary?)))))

    (it "a cancelled simplify turn returns to idle without an error"
      (fn []
        (let [(_seen _submitted simplify _api run-state) (fresh)]
          (command-registry.dispatch "/simplify" run-state)
          (assert.are.equal :running simplify._state.status)
          (events.emit {:type :agent-turn-complete :status :cancelled :result "[cancelled]"})
          (assert.are.equal :idle simplify._state.status)
          (assert.is_nil simplify._state.last-summary)
          (assert.is_nil simplify._state.last-error))))

    (it "reset-conversation returns to idle"
      (fn []
        (let [(_seen _submitted simplify) (fresh)]
          (set simplify._state.status :running)
          (events.emit {:type :reset-conversation})
          (assert.are.equal :idle simplify._state.status))))

    (it "the bundled simplifier agent has parseable frontmatter"
      (fn []
        (let [(fields _body) (frontmatter.parse-file
                               "extensions/behaviors/companions/simplify/examples/simplifier.md")]
          (assert.is_not_nil fields)
          (assert.are.equal "simplifier" fields.name)
          (assert.is_truthy (and fields.description (not= fields.description ""))))))))
