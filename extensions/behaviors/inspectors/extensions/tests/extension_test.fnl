(local test-api (require :fen.core.extensions.test_api))
(local register-registry (require :fen.core.extensions.register))
(local tool-registry (require :fen.core.extensions.register.tool))
(local tools (require :fen.core.tools))

(fn row-texts [rows]
  (let [out []]
    (each [_ row (ipairs rows)]
      (table.insert out (tostring row.text)))
    out))

(fn contains-line? [rows needle]
  (let [texts (row-texts rows)]
    (var found? false)
    (each [_ text (ipairs texts)]
      (when (string.find text needle 1 true)
        (set found? true)))
    found?))

(fn fresh-extension-module []
  (tset package.loaded :fen.extensions.extensions_inspector.commands.extension
        nil)
  (require :fen.extensions.extensions_inspector.commands.extension))

(fn reset-panel-state! []
  (let [state (require :fen.extensions.extensions_inspector.state.extensions)]
    (set state.visible? false)
    (set state.view :extensions)
    (set state.selected-name nil)
    (set state.registry-kind nil)
    (set state.cached-rows nil)
    state))

(fn install-demo-contributions [api]
  (api.register :command {:name :demo :handler (fn [_ _] nil)})
  (api.register :tool {:name :demo_tool :description "demo" :parameters {}})
  (api.register :control {:name :demo-control :keys ["ctrl-d"]})
  (api.register :status {:name :demo-status
                         :side :left
                         :order 5
                         :render (fn [_] "demo")})
  (api.register :panel {:name :demo-panel
                        :placement :above-input
                        :order 7
                        :height (fn [_] 0)
                        :render (fn [_] [])})
  (api.register :hook {:before-tool (fn [_] {:block false})})
  (api.register :introspect
                {:name :demo-snapshot
                 :description "demo snapshot"
                 :snapshot (fn [_] {:ok true})})
  (api.prompt "demo prompt" {:id :demo-prompt :title "Demo Prompt" :order 3})
  (api.on :demo-event (fn [_] nil)))

(describe "extensions inspector registry introspection"
          (fn []
            (before_each (fn []
                           (test-api.reset!)
                           (reset-panel-state!)))
            (it "shows live registered items in extension detail rows"
                (fn []
                  (let [api (test-api.make-runtime-api "demo-ext"
                                                       {:description "Demo extension"})
                        mod (fresh-extension-module)
                        e (. (api.list :extensions) 1)]
                    (install-demo-contributions api)
                    (let [rows (mod._extension-detail-lines api e)]
                      (assert.is_true (contains-line? rows "registered:"))
                      (assert.is_true (contains-line? rows "commands: /demo"))
                      (assert.is_true (contains-line? rows "tools: demo_tool"))
                      (assert.is_true (contains-line? rows
                                                      "controls: demo-control"))
                      (assert.is_true (contains-line? rows
                                                      "status: demo-status"))
                      (assert.is_true (contains-line? rows "panels: demo-panel"))
                      (assert.is_true (contains-line? rows
                                                      "prompt fragments: demo-prompt"))
                      (assert.is_true (contains-line? rows
                                                      "events: demo-event event"))
                      (assert.is_true (contains-line? rows "hooks: before-tool"))
                      (assert.is_true (contains-line? rows
                                                      "introspectors: demo-snapshot"))
                      (assert.is_true (contains-line? rows "snapshots:"))))))
            (it "updates after unregister-by-owner removes stale contributions"
                (fn []
                  (let [api (test-api.make-runtime-api "demo-ext"
                                                       {:description "Demo extension"})
                        mod (fresh-extension-module)
                        e (. (api.list :extensions) 1)]
                    (install-demo-contributions api)
                    (register-registry.unregister-by-owner "demo-ext")
                    (let [rows (mod._extension-detail-lines api e)]
                      (assert.is_true (contains-line? rows "registered:"))
                      (assert.is_true (contains-line? rows "  (none)"))
                      (assert.is_false (contains-line? rows "commands: /demo"))))))
            (it "dispatches /extensions registry subcommands"
                (fn []
                  (let [api (test-api.make-runtime-api "extensions_inspector"
                                                       {:description "inspector"})
                        mod (fresh-extension-module)
                        panel-state (reset-panel-state!)]
                    (mod.register api)
                    (api.commands.dispatch "/extensions registry commands" {})
                    (assert.is_true panel-state.visible?)
                    (assert.are.equal :registry panel-state.view)
                    (assert.are.equal :commands panel-state.registry-kind))))
            (it "marks extensions whose enablement came from settings"
                (fn []
                  (let [api (test-api.make-runtime-api "demo-ext"
                                                       {:description "Demo extension"})
                        mod (fresh-extension-module)
                        ext-state (require :fen.core.extensions.state)]
                    (tset ext-state.extensions "demo-ext"
                          {:manifest {}
                           :status :disabled
                           :enabled-by :settings})
                    (let [e (. (api.list :extensions) 1)
                          rows (mod._extension-detail-lines api e)]
                      (assert.is_true (contains-line? rows
                                                      "status: disabled (settings)"))))))
            (it "persists /extensions enable|disable in settings and runs /reload"
                (fn []
                  (let [h (require :fen.testing)
                        tmp (h.make-tmpdir)
                        settings-path (.. tmp "/fen/settings.json")
                        ext-state (require :fen.core.extensions.state)
                        reloads []
                        errors []]
                    (h.stub-getenv! (fn [name orig]
                                      (if (= name :XDG_CONFIG_HOME) tmp
                                          (orig name))))
                    (let [(ok? err) (pcall (fn []
                                             (let [api (test-api.make-runtime-api "extensions_inspector")
                                                   mod (fresh-extension-module)
                                                   settings (require :fen.core.settings)]
                                               (mod.register api)
                                               (api.register :command
                                                             {:name :reload
                                                              :handler (fn [_
                                                                            state]
                                                                         (table.insert reloads
                                                                                       state))})
                                               (api.on :error
                                                       (fn [ev]
                                                         (table.insert errors
                                                                       ev.error)))
                                               (tset ext-state.extensions
                                                     :decide
                                                     {:manifest {}
                                                      :status :disabled})
                                               (h.write-file settings-path
                                                             "{\"defaultModel\":\"gpt-5.5\",\"extensions\":{\"decide\":{\"model\":\"m1\"}}}")
                                               (let [caller {}]
                                                 (api.commands.dispatch "/extensions enable decide"
                                                                        caller)
                                                 (assert.are.same [caller]
                                                                  reloads))
                                               (assert.are.same {:enabled true
                                                                 :model "m1"}
                                                                (. (settings.load)
                                                                   :extensions
                                                                   :decide))
                                               (assert.are.equal "gpt-5.5"
                                                                 (. (settings.load)
                                                                    :default-model))
                                               (api.commands.dispatch "/extensions disable decide"
                                                                      {})
                                               (assert.are.equal 2
                                                                 (length reloads))
                                               (assert.is_false (. (settings.load)
                                                                   :extensions
                                                                   :decide
                                                                   :enabled))
                                               (api.commands.dispatch "/extensions enable nope"
                                                                      {})
                                               (api.commands.dispatch "/extensions enable decide"
                                                                      {:busy? true})
                                               (api.commands.dispatch "/extensions disable"
                                                                      {})
                                               (assert.are.equal 2
                                                                 (length reloads))
                                               (assert.is_nil (. (settings.load)
                                                                 :extensions
                                                                 :nope))
                                               (assert.is_false (. (settings.load)
                                                                   :extensions
                                                                   :decide
                                                                   :enabled))
                                               (assert.are.same ["extension not found: nope"
                                                                 "/extensions enable is disabled while the agent is running"
                                                                 "usage: /extensions disable <name>"]
                                                                errors))))]
                      (h.restore-getenv!)
                      (h.rmtree tmp)
                      (assert.is_true ok? err)))))
            (it "renders registry-wide rows grouped by kind and owner"
                (fn []
                  (let [api (test-api.make-runtime-api "demo-ext"
                                                       {:description "Demo extension"})
                        mod (fresh-extension-module)]
                    (install-demo-contributions api)
                    (let [rows (mod._registry-lines api :commands)]
                      (assert.is_true (contains-line? rows "Registry: commands"))
                      (assert.is_true (contains-line? rows "/demo"))
                      (assert.is_true (contains-line? rows "owner: demo-ext"))))))
            (it "exposes structured read actions without interactive state"
                (fn []
                  (let [api (test-api.make-runtime-api "demo-ext"
                                                       {:description "Demo extension"})
                        mod (fresh-extension-module)]
                    (install-demo-contributions api)
                    (mod.register api)
                    (let [registered (tool-registry.merged [])
                          list-call (tools.execute-call registered
                                                        {:name :extension
                                                         :arguments {:action "list"}}
                                                        {})
                          show-call (tools.execute-call registered
                                                        {:name :extension
                                                         :arguments {:action "show"
                                                                     :name "demo-ext"}}
                                                        {})
                          registry-call (tools.execute-call registered
                                                            {:name :extension
                                                             :arguments {:action "registry"
                                                                         :kind "commands"}}
                                                            {})]
                      (assert.is_false list-call.result.is-error?)
                      (assert.are.equal :list list-call.result.details.action)
                      (assert.is_true (> (length list-call.result.details.extensions)
                                         0))
                      (assert.is_false show-call.result.is-error?)
                      (assert.are.equal :show show-call.result.details.action)
                      (assert.are.equal "demo-ext"
                                        show-call.result.details.extension.name)
                      (assert.is_false registry-call.result.is-error?)
                      (assert.are.equal :registry
                                        registry-call.result.details.action)
                      (assert.is_not_nil registry-call.result.details.registry))))))
          (it "requires state for reload and preserves rebuild behavior"
              (fn []
                (let [api (test-api.make-runtime-api "extensions_inspector")
                      mod (fresh-extension-module)
                      messages []
                      replacement {:messages []}
                      provider-refresh {:count 0}
                      state {:agent {:messages messages}
                             :opts {}
                             :on-event (fn [_] nil)
                             :agent-extra {}
                             :reload-extension (fn [name]
                                                 (assert.are.equal "demo-ext"
                                                                   name)
                                                 (values true nil))
                             :reload-model-providers (fn []
                                                       (set provider-refresh.count
                                                            (+ provider-refresh.count
                                                               1)))
                             :make-agent-from-opts (fn [_opts _on-event _extra]
                                                     replacement)}]
                  (mod.register api)
                  (let [registered (tool-registry.merged [])
                        missing-state (tools.execute-call registered
                                                          {:name :extension
                                                           :arguments {:action "reload"
                                                                       :name "demo-ext"}}
                                                          {})
                        call (tools.execute-call registered
                                                 {:name :extension
                                                  :arguments {:action "reload"
                                                              :name "demo-ext"}}
                                                 {:state state})]
                    (assert.is_true missing-state.result.is-error?)
                    (assert.is_false call.result.is-error?)
                    (assert.are.equal 1 provider-refresh.count)
                    (assert.are.equal replacement state.agent)
                    (assert.are.equal messages replacement.messages))))))
