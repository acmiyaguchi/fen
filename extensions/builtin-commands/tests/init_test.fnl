;; Tests for the slash command dispatcher and built-in commands.
;;
;; The dispatcher is `extensions.dispatch-command`. Handlers emit through
;; the bus, so tests subscribe a `:*` listener to assert on emitted events.

(local extensions (require :fen.core.extensions))
(local ext-api (require :fen.core.extensions.api))

(fn fresh-bus []
  "Reset the registry, force builtin_commands to re-load against the
   fresh state (so its `(api.register :command ...)` calls populate the
   empty registry), and return a list that captures every emitted event."
  (extensions.reset!)
  (tset package.loaded :fen.extensions.builtin_commands nil)
  (let [seen []]
    (extensions.on :* (fn [ev] (table.insert seen ev)))
    (let [mod (require :fen.extensions.builtin_commands)
          api (ext-api.make-api :builtin_commands)]
      (mod.register api))
    seen))

(fn find-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (and (not found) (= ev.type type-key))
      (set found ev)))
  found)

(describe "extensions.dispatch-command"
  (fn []
    (it "/status toggles the status panel"
      (fn []
        (tset package.loaded :fen.version "test-version")
        (tset package.loaded :fen.extensions.tui.state nil)
        (let [panel-state (require :fen.extensions.builtin_commands.state.status)]
          (set panel-state.visible? false)
          (let [seen (fresh-bus)
                state {:opts {:provider :openai}
                       :agent {:model :gpt-test
                               :provider-name :openai
                               :max-tokens 123
                               :system-prompt "system"
                               :messages []}
                       :session nil}]
            (extensions.dispatch-command "/status" state)
            (assert.is_true panel-state.visible?)
            (let [ev (find-event seen :info)]
              (assert.is_not_nil ev)
              (assert.is_not_nil
                (string.find ev.text "status panel: on" 1 true)))
            ;; Second invocation closes the panel.
            (extensions.dispatch-command "/status" state)
            (assert.is_false (or panel-state.visible? false))))))

    (it "unknown commands emit a friendly error"
      (fn []
        (let [seen (fresh-bus)]
          (extensions.dispatch-command "/no-such-cmd" {})
          (let [ev (find-event seen :error)]
            (assert.is_not_nil ev)
            (assert.is_not_nil
              (string.find ev.error "unknown command" 1 true))))))

    (it "idle-only commands are blocked while busy"
      (fn []
        (let [seen (fresh-bus)]
          (extensions.dispatch-command "/new" {:busy? true})
          (let [ev (find-event seen :error)]
            (assert.is_not_nil ev)
            (assert.is_not_nil
              (string.find ev.error "disabled while the agent is running"
                            1 true))))))

    (it "handler errors are pcall'd into a bus :error"
      (fn []
        (extensions.reset!)
        (let [api (ext-api.make-api :test-owner)
              seen []]
          (extensions.on :* (fn [ev] (table.insert seen ev)))
          (api.register :command
                        {:name :crash
                         :handler (fn [_ _] (error "boom"))})
          (extensions.dispatch-command "/crash" {})
          (let [ev (find-event seen :error)]
            (assert.is_not_nil ev)
            (assert.is_not_nil
              (string.find ev.error "/crash:" 1 true))
            (assert.is_not_nil
              (string.find ev.error "boom" 1 true))))))

    (it "/prompt toggles the prompt-fragments panel"
      (fn []
        (let [panel-state (require :fen.extensions.builtin_commands.state.prompt)]
          (set panel-state.visible? false)
          (let [seen (fresh-bus)
                api (ext-api.make-api :prompt-test)]
            (api.prompt "body" {:order 10
                                :id :body
                                :title "Body"
                                :description "Main prompt body."})
            (extensions.dispatch-command "/prompt" {:agent {:system-prompt "hello prompt"}})
            (assert.is_true panel-state.visible?)
            (let [ev (find-event seen :info)]
              (assert.is_not_nil ev)
              (assert.is_not_nil
                (string.find ev.text "prompt panel: on" 1 true)))))))

    (it "/prompt rendered emits the rendered system prompt"
      (fn []
        (let [seen (fresh-bus)]
          (extensions.dispatch-command "/prompt rendered" {:agent {:system-prompt "hello prompt"}})
          (let [ev (find-event seen :assistant-text)]
            (assert.is_not_nil ev)
            (assert.are.equal "hello prompt" ev.text)))))

    (it "/help lists registered commands"
      (fn []
        (let [seen (fresh-bus)]
          (extensions.dispatch-command "/help" {})
          (let [ev (find-event seen :assistant-text)]
            (assert.is_not_nil ev)
            (assert.is_not_nil (string.find ev.text "/new" 1 true))
            (assert.is_not_nil (string.find ev.text "/prompt" 1 true))
            (assert.is_nil (string.find ev.text "/prompt-fragments" 1 true))
            (assert.is_not_nil (string.find ev.text "/reload" 1 true))
            (assert.is_not_nil (string.find ev.text "/status" 1 true))))))))
