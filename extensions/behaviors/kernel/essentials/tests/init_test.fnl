;; Tests for the slash command dispatcher and the essentials built-in commands
;; (/thinking, /help) plus generic dispatcher behavior.
;;
;; Per-extension panel behavior (/status, /prompt, /queue, /extensions) lives in
;; tests colocated with those inspector extensions.
;;
;; The dispatcher is `command-registry.dispatch`. Handlers emit through the bus,
;; so tests subscribe a `:*` listener to assert on emitted events.

(local h (require :fen.testing))
(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))
(local model-command (require :fen.extensions.essentials.commands.model))

;; Registered so /help can list their commands (/new, /reload, /status,
;; /prompt) alongside /help itself.
(local help-extensions [:essentials :sessions :status :prompt])

(fn fresh-bus [names]
  "Reset the registry, force the named first-party extensions to re-load
   against the fresh state (so their `(api.register :command ...)` calls
   populate the empty registry), and return a list that captures every emitted
   event."
  (test-api.reset!)
  (each [_ name (ipairs names)]
    (tset package.loaded (.. "fen.extensions." (tostring name)) nil))
  (let [seen []]
    (events.on :* (fn [ev] (table.insert seen ev)))
    (each [_ name (ipairs names)]
      (let [mod (require (.. "fen.extensions." (tostring name)))
            api (test-api.make-runtime-api name)]
        (mod.register api)))
    seen))

(fn find-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (and (not found) (= ev.type type-key))
      (set found ev)))
  found)

(describe "command dispatcher and essentials commands"
  (fn []
    (it "unknown commands emit a friendly error"
      (fn []
        (let [seen (fresh-bus [:essentials])]
          (command-registry.dispatch "/no-such-cmd" {})
          (let [ev (find-event seen :error)]
            (assert.is_not_nil ev)
            (assert.is_not_nil
              (string.find ev.error "unknown command" 1 true))))))

    (it "idle-only commands are blocked while busy"
      (fn []
        (let [seen (fresh-bus [:sessions])]
          (command-registry.dispatch "/new" {:busy? true})
          (let [ev (find-event seen :error)]
            (assert.is_not_nil ev)
            (assert.is_not_nil
              (string.find ev.error "disabled while the agent is running"
                            1 true))))))

    (it "handler errors are pcall'd into a bus :error"
      (fn []
        (test-api.reset!)
        (let [api (test-api.make-runtime-api :test-owner)
              seen []]
          (events.on :* (fn [ev] (table.insert seen ev)))
          (api.register :command
                        {:name :crash
                         :handler (fn [_ _] (error "boom"))})
          (command-registry.dispatch "/crash" {})
          (let [ev (find-event seen :error)]
            (assert.is_not_nil ev)
            (assert.is_not_nil
              (string.find ev.error "/crash:" 1 true))
            (assert.is_not_nil
              (string.find ev.error "boom" 1 true))))))

    (it "/model exposes live model choices for argument completion"
      (fn []
        (var command nil)
        (let [models [{:provider :openai :id :gpt-5.5 :api :responses}
                      {:provider :anthropic :id :claude-sonnet-4-6}]
              api {:register (fn [_kind spec] (set command spec))
                   :models {:list (fn [opts]
                                           (assert.are.equal :openai opts.provider)
                                           models)
                            :canonical-id (fn [m]
                                            (.. (tostring m.provider) "/"
                                                (tostring m.id)))}}]
          (model-command.register api)
          (let [choices (command.complete "" {:state {:opts {:provider :openai}
                                                        :agent {:model :gpt-5.5}}})]
            (assert.are.equal 2 (length choices))
            (assert.are.equal "anthropic/claude-sonnet-4-6"
                              (. choices 1 :value))
            (assert.are.equal "openai/gpt-5.5" (. choices 2 :value))
            (assert.is_truthy
              (string.find (. choices 2 :description) "current" 1 true))))))

    (it "/model seeds the selector for a non-exact interactive query"
      (fn []
        (var command nil)
        (var select-opts nil)
        (let [models [{:provider :anthropic :id :claude-sonnet-4-6}
                      {:provider :anthropic :id :claude-haiku-4-5}]
              api {:register (fn [_kind spec] (set command spec))
                   :emit (fn [_ev] nil)
                   :models {:list (fn [_opts] models)
                            :canonical-id (fn [m]
                                            (.. (tostring m.provider) "/"
                                                (tostring m.id)))
                            :resolve (fn [_query _available]
                                       {:status :ok :model (. models 1)})}
                   :ui {:has-ui? (fn [] true)
                        :select (fn [opts]
                                  (set select-opts opts)
                                  nil)}}]
          (model-command.register api)
          (command.handler "snt" {:opts {:provider :anthropic}
                                   :agent {:model :claude-haiku-4-5}})
          (assert.are.equal "snt" select-opts.initial-query)
          (assert.are.equal 2 (length select-opts.choices)))))

    (it "/model inline completion refreshes from the shared background catalog"
      (fn []
        (var command nil)
        (var runtime-tick nil)
        (var emitted nil)
        (var refreshed? false)
        (let [static [{:provider :sakana :id :fallback}]
              dynamic [{:provider :sakana :id :fugu}]
              api {:register (fn [_kind spec] (set command spec))
                   :on (fn [event handler]
                         (when (= event :runtime-tick)
                           (set runtime-tick handler)))
                   :emit (fn [ev] (set emitted ev))
                   :models {:list (fn [opts]
                                           (if (= opts.dynamic-mode :cached)
                                               (if refreshed? dynamic static)
                                               (do (opts.yield)
                                                   (set refreshed? true)
                                                   dynamic)))
                            :canonical-id (fn [m]
                                            (.. (tostring m.provider) "/"
                                                (tostring m.id)))}
                   :ui {:has-ui? (fn [] true)}}
              ctx {:state {:opts {:provider :sakana}
                           :agent {:model :fallback}}}]
          (model-command.register api)
          (let [before (command.complete "" ctx)]
            (assert.are.equal "sakana/fallback" (. before 1 :label)))
          (runtime-tick {})
          (runtime-tick {})
          (assert.are.equal :model-catalog-updated emitted.type)
          (let [after (command.complete "" ctx)]
            (assert.are.equal "sakana/fugu" (. after 1 :label))))))

    (it "/model opens from cached choices and refreshes dynamic choices cooperatively"
      (fn []
        (var command nil)
        (var select-opts nil)
        (var initial-label nil)
        (var first-update nil)
        (var second-update nil)
        (var refreshed? false)
        (let [static [{:provider :sakana :id :fallback}]
              dynamic [{:provider :sakana :id :fugu}]
              api {:register (fn [_kind spec] (set command spec))
                   :emit (fn [_ev] nil)
                   :models {:list (fn [opts]
                                           (if (= opts.dynamic-mode :cached)
                                               (if refreshed? dynamic static)
                                               (do (opts.yield)
                                                   (set refreshed? true)
                                                   dynamic)))
                            :canonical-id (fn [m]
                                            (.. (tostring m.provider) "/"
                                                (tostring m.id)))
                            :resolve (fn [_query _available]
                                       {:status :miss :candidates []})}
                   :ui {:has-ui? (fn [] true)
                        :select (fn [opts]
                                  (set select-opts opts)
                                  (set initial-label (. opts.choices 1 :label))
                                  (set first-update (opts.on-tick {}))
                                  (set second-update (opts.on-tick {}))
                                  nil)}}]
          (model-command.register api)
          (command.handler "" {:opts {:provider :sakana}
                                :agent {:model :fallback}})
          (assert.are.equal "* sakana/fallback" initial-label)
          (assert.are.equal "switch model · loading…" first-update.label)
          (assert.are.equal "switch model" second-update.label)
          (assert.are.equal "  sakana/fugu"
                            (. second-update.choices 1 :label))
          (assert.is_function select-opts.on-tick))))

    (it "/model keeps a unique exact id non-interactive"
      (fn []
        (var command nil)
        (var selected? false)
        (let [models [{:provider :anthropic :id :claude-sonnet-4-6}]
              api {:register (fn [_kind spec] (set command spec))
                   :emit (fn [_ev] nil)
                   :settings {:set-defaults! (fn [_provider _model] true)}
                   :models {:list (fn [_opts] models)
                            :canonical-id (fn [m]
                                            (.. (tostring m.provider) "/"
                                                (tostring m.id)))
                            :resolve (fn [_query _available]
                                       {:status :ok :model (. models 1)})}
                   :ui {:has-ui? (fn [] true)
                        :select (fn [_opts] (set selected? true))}}
              state {:opts {:provider :openai}
                     :agent {:model :old :messages []}
                     :make-agent-from-opts
                     (fn [opts _on-event _extra]
                       {:model opts.model :messages []})}]
          (model-command.register api)
          (command.handler "claude-sonnet-4-6" state)
          (assert.is_false selected?)
          (assert.are.equal :anthropic state.opts.provider)
          (assert.are.equal :claude-sonnet-4-6 state.agent.model))))

    (it "/model keeps fuzzy resolution non-interactive without a UI"
      (fn []
        (var command nil)
        (let [model {:provider :anthropic :id :claude-sonnet-4-6}
              api {:register (fn [_kind spec] (set command spec))
                   :emit (fn [_ev] nil)
                   :settings {:set-defaults! (fn [_provider _model] true)}
                   :models {:list (fn [_opts] [model])
                            :canonical-id (fn [m]
                                            (.. (tostring m.provider) "/"
                                                (tostring m.id)))
                            :resolve (fn [_query _available]
                                       {:status :ok :model model})}
                   :ui {:has-ui? (fn [] false)
                        :select (fn [_opts]
                                  (error "headless query should not select"))}}
              state {:opts {:provider :openai}
                     :agent {:model :old :messages []}
                     :make-agent-from-opts
                     (fn [opts _on-event _extra]
                       {:model opts.model :messages []})}]
          (model-command.register api)
          (command.handler "snt" state)
          (assert.are.equal :anthropic state.opts.provider)
          (assert.are.equal :claude-sonnet-4-6 state.agent.model))))

    (it "/thinking sets effort, clears exact overrides, rebuilds, persists, and refreshes status"
      (fn []
        (let [tmp (h.make-tmpdir)]
          (h.stub-getenv!
            (fn [name orig]
              (if (= name :XDG_CONFIG_HOME) tmp
                  (= name :HOME) tmp
                  (orig name))))
          (let [seen (fresh-bus [:essentials])
                messages [{:role :user :content []}]
                rebuilds []
                state {:opts {:provider :openai-codex
                              :thinking-budget 8192
                              :reasoning-effort :medium}
                       :agent {:model :gpt-5.5
                               :provider-name :openai-codex
                               :thinking-status "reason:medium"
                               :messages messages}
                       :make-agent-from-opts
                       (fn [opts _on-event _extra]
                         (table.insert rebuilds {:thinking opts.thinking
                                                 :thinking-budget opts.thinking-budget
                                                 :reasoning-effort opts.reasoning-effort})
                         {:model :gpt-5.5
                          :provider-name :openai-codex
                          :thinking-status (.. "reason:" (tostring opts.thinking))
                          :messages []})}]
            (command-registry.dispatch "/thinking high" state)
            (assert.are.equal :high state.opts.thinking)
            (assert.is_nil state.opts.thinking-budget)
            (assert.is_nil state.opts.reasoning-effort)
            (assert.are.equal messages state.agent.messages)
            (assert.are.equal 1 (length rebuilds))
            (assert.is_nil (. rebuilds 1 :thinking-budget))
            (assert.is_nil (. rebuilds 1 :reasoning-effort))
            (let [status (find-event seen :set-status-info)]
              (assert.is_not_nil status)
              (assert.are.equal "reason:high" status.info.thinking-status))
            (let [settings (h.reload-module :fen.core.settings)
                  out (settings.load)]
              (assert.are.equal :high out.default-thinking)))
          (h.restore-getenv!)
          (h.rmtree tmp))))

    (it "/thinking blocks delegates visibility to presenters"
      (fn []
        (let [seen (fresh-bus [:essentials])]
          (command-registry.dispatch "/thinking blocks off" {:opts {} :agent {}})
          (let [ev (find-event seen :set-thinking-blocks)]
            (assert.is_not_nil ev)
            (assert.is_false ev.visible?)))))

    (it "/help lists registered commands"
      (fn []
        (let [seen (fresh-bus help-extensions)]
          (command-registry.dispatch "/help" {})
          (let [ev (find-event seen :assistant-text)]
            (assert.is_not_nil ev)
            (assert.is_not_nil (string.find ev.text "/new" 1 true))
            (assert.is_not_nil (string.find ev.text "/prompt" 1 true))
            (assert.is_nil (string.find ev.text "/prompt-fragments" 1 true))
            (assert.is_not_nil (string.find ev.text "/reload" 1 true))
            (assert.is_not_nil (string.find ev.text "/status" 1 true))))))))
