(local test-api (require :fen.core.extensions.test_api))
(local register-registry (require :fen.core.extensions.register))
(local prompt-registry (require :fen.core.extensions.register.prompt))

(fn handle-result [kind name owner unregister]
  {: kind : name : owner : unregister})
(local extensions
  {:reset! test-api.reset!
   :prompt (fn [text-or-fn ?opts owner]
             (prompt-registry.contribute text-or-fn ?opts owner handle-result))})

(describe "core.prompt"
  (fn []
    (var prompt nil)

    (before_each
      (fn []
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
        (assert.are.equal "" (prompt.build {} []))))

    (it "reports per-fragment sizes without exposing fragment text"
      (fn []
        (extensions.prompt "body-1234" {:id :body :order 50} :test)
        (extensions.prompt (fn [ctx]
                             (.. "tools=" (tostring (length ctx.tools))))
                           {:id :tools :order 10}
                           :test)
        (let [rows (prompt.stats {:system "ignored"} [{:name :bash} {:name :read}])]
          (assert.are.equal 2 (length rows))
          ;; sorted by order: tools (10) before body (50)
          (let [first (. rows 1)
                second (. rows 2)]
            (assert.are.equal :tools first.id)
            (assert.is_true first.dynamic?)
            (assert.are.equal (length "tools=2") first.bytes)
            (assert.are.equal :body second.id)
            (assert.is_false second.dynamic?)
            (assert.are.equal (length "body-1234") second.bytes)
            ;; no rendered text field is exposed
            (assert.is_nil first.text)
            (assert.is_nil (. first :text-or-fn))
            (assert.is_true (>= first.approx-tokens 0))
            ;; Total metadata accounts for the real "\n\n" separator while
            ;; still withholding rendered text.
            (assert.are.equal (length "tools=2\n\nbody-1234") (. rows :total-bytes))
            (assert.are.equal 2 (. rows :non-empty-count))))))

    (it "reports zero bytes for empty fragments"
      (fn []
        (extensions.prompt "" {:id :blank :order 5} :test)
        (let [rows (prompt.stats {} [])]
          (assert.are.equal 1 (length rows))
          (assert.are.equal 0 (. rows 1 :bytes))
          (assert.are.equal 0 (. rows 1 :approx-tokens))
          (assert.are.equal 0 (. rows :total-bytes))
          (assert.are.equal 0 (. rows :total-approx-tokens))
          (assert.are.equal 0 (. rows :non-empty-count)))))))
