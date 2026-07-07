;; Tests for the /prompt command: the prompt-fragments panel toggle and the
;; `/prompt rendered` transcript blob.
;;
;; Handlers emit through the bus, so tests subscribe a `:*` listener to assert
;; on emitted events.

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))

(fn fresh-bus [names]
  "Reset the registry, force the named first-party extensions to re-load
   against the fresh state, and return a list that captures every emitted
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

(describe "fen.extensions.prompt"
  (fn []
    (it "/prompt toggles the prompt-fragments panel"
      (fn []
        (let [panel-state (require :fen.extensions.prompt.state.prompt)]
          (set panel-state.visible? false)
          (let [seen (fresh-bus [:prompt])
                api (test-api.make-runtime-api :prompt-test)]
            (api.prompt "body" {:order 10
                                :id :body
                                :title "Body"
                                :description "Main prompt body."})
            (command-registry.dispatch "/prompt" {:agent {:system-prompt "hello prompt"}})
            (assert.is_true panel-state.visible?)
            (let [ev (find-event seen :info)]
              (assert.is_not_nil ev)
              (assert.is_not_nil
                (string.find ev.text "prompt panel: on" 1 true)))))))

    (it "/prompt rendered emits the rendered system prompt"
      (fn []
        (let [seen (fresh-bus [:prompt])]
          (command-registry.dispatch "/prompt rendered" {:agent {:system-prompt "hello prompt"}})
          (let [ev (find-event seen :assistant-text)]
            (assert.is_not_nil ev)
            (assert.are.equal "hello prompt" ev.text)))))))
