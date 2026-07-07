;; Tests for the /status command and status panel toggle.
;;
;; Handlers emit through the bus, so tests subscribe a `:*` listener to assert
;; on emitted events.

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))

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

(describe "fen.extensions.status"
  (fn []
    (it "/status toggles the status panel"
      (fn []
        (tset package.loaded :fen.version "test-version")
        (tset package.loaded :fen.extensions.tui.state nil)
        (let [panel-state (require :fen.extensions.status.state.status)]
          (set panel-state.visible? false)
          (let [seen (fresh-bus [:status])
                state {:opts {:provider :openai}
                       :agent {:model :gpt-test
                               :provider-name :openai
                               :max-tokens 123
                               :system-prompt "system"
                               :messages []}
                       :session nil}]
            (command-registry.dispatch "/status" state)
            (assert.is_true panel-state.visible?)
            (let [ev (find-event seen :info)]
              (assert.is_not_nil ev)
              (assert.is_not_nil
                (string.find ev.text "status panel: on" 1 true)))
            ;; Second invocation closes the panel.
            (command-registry.dispatch "/status" state)
            (assert.is_false (or panel-state.visible? false))))))))
