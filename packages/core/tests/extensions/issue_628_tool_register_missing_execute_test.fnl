;; Known bug #628: register :tool accepts a spec with no :execute, unlike :command/:hook, and it fails only when called.

(local {: known-bug} (require :fen.testing))
(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local tools (require :fen.core.tools))

(fn advertised? [name]
  (var found? false)
  (each [_ d (ipairs (tools.descriptors (tool-registry.merged [])))]
    (when (= (tostring d.name) name)
      (set found? true)))
  found?)

(describe "#628 register :tool without :execute"
          (fn []
            (before_each (fn [] (test-api.reset!)))
            (after_each (fn [] (test-api.reset!)))
            (it "is accepted and advertised, then fails at call time"
                (fn []
                  (known-bug 628
                             (fn []
                               (let [api (test-api.make-runtime-api :probe)
                                     (tool-ok? _) (pcall api.register :tool
                                                         {:name :no_exec
                                                          :parameters {:type :object}})
                                     ;; Contrast: the sibling kinds reject a missing callable.
                                     (command-ok? command-err) (pcall api.register
                                                                      :command
                                                                      {:name :no-handler})
                                     (hook-ok? hook-err) (pcall api.register
                                                                :hook {})
                                     call {:name :no_exec :arguments {}}
                                     blocking (tools.execute-call (tool-registry.merged [])
                                                                  call {})
                                     (coop-ok? coop-err) (pcall tools.execute-call
                                                                (tool-registry.merged [])
                                                                call {}
                                                                (fn [] nil))]
                                 (and (= true tool-ok?) (advertised? :no_exec)
                                      (= false command-ok?)
                                      (not= nil
                                            (string.find (tostring command-err)
                                                         "requires {:handler fn}"
                                                         1 true))
                                      (= false hook-ok?)
                                      (not= nil
                                            (string.find (tostring hook-err)
                                                         "requires {:before-tool fn}"
                                                         1 true))
                                      ;; The late failure: blocking callers get a tool error...
                                      (= true blocking.result.is-error?)
                                      ;; ...cooperative (agent) callers get a raw nil-call raise.
                                      (= false coop-ok?)
                                      (not= nil
                                            (string.find (tostring coop-err)
                                                         "field 'execute'" 1
                                                         true))))))))))
