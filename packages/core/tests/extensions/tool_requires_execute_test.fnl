;; Regression for #628: register :tool validates :execute like :command and :hook do.

(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local tools (require :fen.core.tools))

(fn advertised? [name]
  (var found? false)
  (each [_ d (ipairs (tools.descriptors (tool-registry.merged [])))]
    (when (= (tostring d.name) name)
      (set found? true)))
  found?)

(describe "#628 register :tool validates :execute"
          (fn []
            (before_each (fn [] (test-api.reset!)))
            (after_each (fn [] (test-api.reset!)))
            (it "rejects a spec without a function :execute at registration"
                (fn []
                  (let [api (test-api.make-runtime-api :probe)
                        (ok? err) (pcall api.register :tool
                                         {:name :no_exec
                                          :parameters {:type :object}})
                        (str-ok? _) (pcall api.register :tool
                                           {:name :str_exec :execute "x"})]
                    (assert.is_false ok?)
                    (assert.is_not_nil (string.find (tostring err)
                                                    "requires {:execute fn}" 1
                                                    true))
                    (assert.is_false str-ok?)
                    (assert.is_false (advertised? :no_exec))
                    (assert.is_false (advertised? :str_exec)))))
            (it "still accepts a tool with a function :execute"
                (fn []
                  (let [api (test-api.make-runtime-api :probe)]
                    (api.register :tool
                                  {:name :ok_tool
                                   :parameters {:type :object}
                                   :execute (fn [] nil)})
                    (assert.is_true (advertised? :ok_tool)))))))
