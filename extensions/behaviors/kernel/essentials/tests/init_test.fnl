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
