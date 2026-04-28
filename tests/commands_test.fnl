;; Tests for the slash command dispatcher and built-in commands.
;;
;; The dispatcher is `extensions.dispatch-command`. Handlers emit through
;; the bus, so tests subscribe a `:*` listener to assert on emitted events.

(local extensions (require :core.extensions))

(fn fresh-bus []
  "Reset the registry, force core.builtin_commands to re-load against the
   fresh state (so its `(api.register :command ...)` calls populate the
   empty registry), and return a list that captures every emitted event."
  (extensions.reset!)
  (tset package.loaded :core.builtin_commands nil)
  (let [seen []]
    (extensions.on :* (fn [ev] (table.insert seen ev)))
    (require :core.builtin_commands)
    seen))

(fn find-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (and (not found) (= ev.type type-key))
      (set found ev)))
  found)

(describe "extensions.dispatch-command"
  (fn []
    (it "/status emits an assistant-text event with the build version"
      (fn []
        (tset package.loaded :version "test-version")
        ;; tui.state is consulted by /status's token summary helper —
        ;; provide a minimal stand-in.
        (tset package.loaded :extensions.tui.state
              {:status-info {:cum-input 0 :cum-output 0
                             :cum-cache-read 0 :cum-cache-write 0
                             :last-input 0}})
        (let [seen (fresh-bus)
              state {:opts {:provider :openai}
                     :agent {:model :gpt-test
                             :provider-api :openai-completions
                             :max-tokens 123
                             :system-prompt "system"
                             :messages []}
                     :session nil}]
          (extensions.dispatch-command "/status" state)
          (let [ev (find-event seen :assistant-text)]
            (assert.is_not_nil ev)
            (assert.is_not_nil
              (string.find ev.text "version: test-version" 1 true))))))

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
        (let [api (extensions.make-api :test-owner)
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

    (it "/help lists registered commands"
      (fn []
        (let [seen (fresh-bus)]
          (extensions.dispatch-command "/help" {})
          (let [ev (find-event seen :assistant-text)]
            (assert.is_not_nil ev)
            (assert.is_not_nil (string.find ev.text "/new" 1 true))
            (assert.is_not_nil (string.find ev.text "/reload" 1 true))
            (assert.is_not_nil (string.find ev.text "/status" 1 true))))))))
