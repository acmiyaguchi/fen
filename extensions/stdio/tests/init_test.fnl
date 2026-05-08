(local extensions (require :fen.core.extensions))
(local ext-api (require :fen.core.extensions.api))

(describe "stdio presenter"
  (before_each
    (fn []
      (extensions.reset!)
      (tset package.loaded :fen.extensions.stdio nil)))

  (after_each
    (fn []
      (extensions.reset!)
      (tset package.loaded :fen.extensions.stdio nil)))

  (it "registers an active presenter without loading termbox2"
    (fn []
      (let [stdio (require :fen.extensions.stdio)
            api (ext-api.make-api :stdio)]
        (stdio.register api)
        (let [presenter (extensions.active-presenter)]
        (assert.is_table stdio)
        (assert.is_table presenter)
        (assert.are.equal :stdio presenter.name)
        (assert.is_true presenter.active?)
        (assert.is_function presenter.run)
        (assert.is_table presenter.ui)
        (assert.is_function presenter.ui.notify)
        (assert.is_function presenter.ui.prompt)
          (assert.is_function presenter.ui.select))))))
