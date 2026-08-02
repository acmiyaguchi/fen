;; Focused coverage for the repository-local .fen/extensions/fennel-eval drop-in.

(local fennel (require :fennel))
(local h (require :fen.testing))

(local extension-dir ".fen/extensions/fennel-eval")
(local init-path (.. extension-dir "/init.fnl"))
(local tool-path (.. extension-dir "/tool.fnl"))

(fn load-file [path]
  (fennel.dofile path))

(fn mock-extension-api [tool]
  (let [registered []
        api {:marker "registry"
             :load (fn [name]
                     (assert.are.equal :tool name)
                     tool)
             :register (fn [kind spec]
                         (table.insert registered {:kind kind :spec spec}))}]
    {:api api :registered registered}))

(describe "repo-local fennel_eval extension"
  (fn []
    (after_each (fn [] (h.restore-getenv!)))

    (it "does not register without FEN_FENNEL_EVAL=1"
      (fn []
        ;; The extension API is a narrow mock, rather than a live registry.
        ;; Keep it in package.loaded so this focused file never initializes
        ;; extension-loader state as a side effect of testing the drop-in.
        (let [tool (load-file tool-path)
              mocked (mock-extension-api tool)]
          (tset package.loaded :fennel_eval_test.extension_api mocked.api)
          (h.stub-getenv! (fn [name orig]
                            (if (= name :FEN_FENNEL_EVAL) nil (orig name))))
          ((load-file init-path) (require :fennel_eval_test.extension_api))
          (assert.are.equal 0 (length mocked.registered))
          (tset package.loaded :fennel_eval_test.extension_api nil))))

    (it "registers with opt-in and evaluates live bindings"
      (fn []
        (let [tool (load-file tool-path)
              mocked (mock-extension-api tool)]
          (tset package.loaded :fennel_eval_test.extension_api mocked.api)
          (h.stub-getenv! (fn [name orig]
                            (if (= name :FEN_FENNEL_EVAL) "1" (orig name))))
          ((load-file init-path) (require :fennel_eval_test.extension_api))
          (assert.are.equal 1 (length mocked.registered))
          (let [entry (. mocked.registered 1)
                execute entry.spec.execute
                result (execute {:expr "(+ agent.answer state.offset)"}
                                {:agent {:answer 40} :state {:offset 2}})]
            (assert.are.equal :tool entry.kind)
            (assert.are.equal :fennel_eval entry.spec.name)
            (assert.is_false result.is-error?)
            (assert.are.equal "42" (. (. result.content 1) :text)))
          (tset package.loaded :fennel_eval_test.extension_api nil))))

    (it "binds the extension registry and returns eval errors as tool errors"
      (fn []
        (let [tool (load-file tool-path)
              api {:marker "registry"}
              registry-result (tool.execute {:expr "extensions.marker"} {} api)
              error-result (tool.execute {:expr "(error \"boom\")"} {} api)]
          (assert.is_false registry-result.is-error?)
          (assert.are.equal "\"registry\"" (. (. registry-result.content 1) :text))
          (assert.is_true error-result.is-error?)
          (assert.is_truthy (string.find (. (. error-result.content 1) :text)
                                        "boom" 1 true)))))

    (it "truncates rendered output at the agent_state default"
      (fn []
        (let [tool (load-file tool-path)
              result (tool.execute {:expr "(string.rep \"x\" 12)" :max_bytes 5}
                                   {} {})]
          (assert.is_false result.is-error?)
          (assert.are.equal "\"xxxx\n[truncated: kept 5 bytes]"
                            (. (. result.content 1) :text)))))))
