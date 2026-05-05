;; Tests for the docs extension command.

(local extensions (require :fen.core.extensions))

(fn fresh-docs []
  (extensions.reset!)
  (tset package.loaded :fen.extensions.docs nil)
  (let [seen []]
    (extensions.on :* (fn [ev] (table.insert seen ev)))
    (require :fen.extensions.docs)
    seen))

(fn find-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (and (not found) (= ev.type type-key))
      (set found ev)))
  found)

(describe "docs extension"
  (fn []
    (it "/docs toggles the docs panel"
      (fn []
        (let [panel-state (require :fen.extensions.docs.state)]
          (set panel-state.visible? false)
          (set panel-state.selected-topic nil)
          (let [seen (fresh-docs)]
            (extensions.dispatch-command "/docs" {})
            (assert.is_true panel-state.visible?)
            (let [ev (find-event seen :info)]
              (assert.is_not_nil ev)
              (assert.is_not_nil
                (string.find ev.text "docs panel: on" 1 true)))))))

    (it "/docs can show contract details"
      (fn []
        (let [seen (fresh-docs)]
          (extensions.dispatch-command "/docs types Message" {})
          (let [ev (find-event seen :assistant-text)]
            (assert.is_not_nil ev)
            (assert.is_not_nil (string.find ev.text "# Message" 1 true))
            (assert.is_not_nil (string.find ev.text "Variants:" 1 true))))))))
