(describe "core.prompt"
  (fn []
    (var prompt nil)
    (var extensions nil)

    (before_each
      (fn []
        (set extensions (require :fen.core.extensions))
        (extensions.reset!)
        (tset package.loaded :fen.core.prompt nil)
        (set prompt (require :fen.core.prompt))))

    (after_each
      (fn []
        (extensions.reset!)))

    (it "builds the render context from opts and tools"
      (fn []
        (let [tools [{:name :bash :snippet "Run commands"}]
              ctx (prompt.build-context {:system "custom"} tools)]
          (assert.are.equal "custom" ctx.opts.system)
          (assert.are.equal tools ctx.tools))))

    (it "renders registered prompt fragments in extension order"
      (fn []
        (extensions.prompt "body" {:id :body :order 50} :test)
        (extensions.prompt (fn [ctx]
                             (.. "tools=" (tostring (length ctx.tools))))
                           {:id :tools :order 10}
                           :test)
        (let [text (prompt.build {:system "ignored by core"}
                                 [{:name :bash} {:name :read}])]
          (assert.are.equal "tools=2\n\nbody" text))))

    (it "returns an empty string when no fragments are registered"
      (fn []
        (assert.are.equal "" (prompt.build {} []))))))
