;; Tool-related test cases.

(local ext-api (require :fen.core.extensions.test_api))
(local th (require :fen.testing.tools))
(local tools th.tools)
(local extensions th.extensions)
(local registry th.registry)
(local types th.types)
(local json th.json)
(local text-util (require :fen.util.text))
(local h th.h)
(local read-file th.read-file)
(local first-text th.first-text)
(local execute th.execute)
(local execute-coop th.execute-coop)
(import-macros {: with-tmpdir : with-tmpfile} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(describe "core.tools.execute-call"
  (fn []
    (it "keeps the public core.tools surface compact"
      (fn []
        (assert.is_function tools.descriptors)
        (assert.is_function tools.execute-call)
        (assert.is_nil tools.execute)
        (assert.is_nil tools.execute-coop)
        (assert.is_nil tools.execute-call-coop)
        (assert.is_nil tools.find-tool)))

    (it "wraps an AgentToolResult as a canonical ToolResultMessage"
      (fn []
        (let [reg [{:name :probe :label "Probe" :description ""
                    :parameters {}
                    :execute (fn [_]
                               {:content [(types.text-block "ok")]
                                :is-error? false
                                :details {:n 1}})}]
              out (tools.execute-call reg
                                      {:type :tool-call
                                       :id "call-1"
                                       :name :probe
                                       :arguments {}}
                                      {})]
          (assert.are.equal :tool-result out.message.role)
          (assert.are.equal "call-1" out.message.tool-call-id)
          (assert.are.equal :probe out.message.tool-name)
          (assert.are.equal "ok" (first-text out.message.content))
          (assert.are.same {:n 1} out.message.details)
          (assert.are.same out.result.content out.message.content))))

    (it "sanitizes unsafe text before wrapping tool results"
      (fn []
        (let [poison (.. "ok" (string.char 0) (string.char 255) "done")
              reg [{:name :probe :label "Probe" :description ""
                    :parameters {}
                    :execute (fn [_]
                               {:content [(types.text-block poison)]
                                :is-error? false
                                :details {:raw poison}})}]
              out (tools.execute-call reg
                                      {:type :tool-call
                                       :id "call-poison"
                                       :name :probe
                                       :arguments {}}
                                      {})
              body (first-text out.message.content)]
          (assert.are.equal "call-poison" out.message.tool-call-id)
          (assert.are.equal :probe out.message.tool-name)
          (assert.is_false out.message.is-error?)
          (assert.is_truthy (string.find body "\\x00" 1 true))
          (assert.is_truthy (string.find body "\\xFF" 1 true))
          (assert.is_truthy (string.find body "tool output sanitized" 1 true))
          (assert.are.same {:raw poison} out.message.details)
          (assert.are.same out.result.content out.message.content))))

    (it "caps oversized tool results while preserving pairing"
      (fn []
        (let [big (string.rep "a" (+ text-util.DEFAULT-MAX-TOOL-RESULT-BYTES 10))
              reg [{:name :probe :label "Probe" :description ""
                    :parameters {}
                    :execute (fn [_]
                               {:content [(types.text-block big)]
                                :is-error? false})}]
              out (tools.execute-call reg
                                      {:type :tool-call
                                       :id "call-big"
                                       :name :probe
                                       :arguments {}}
                                      {})
              body (first-text out.message.content)]
          (assert.are.equal "call-big" out.message.tool-call-id)
          (assert.are.equal :probe out.message.tool-name)
          (assert.is_truthy (string.find body "tool output truncated" 1 true))
          (assert.is_truthy
            (string.find body
                         (.. "kept " text-util.DEFAULT-MAX-TOOL-RESULT-BYTES)
                         1 true)))))

    (it "leaves clean small results byte-identical and marker-free"
      (fn []
        (let [reg [{:name :probe :label "Probe" :description ""
                    :parameters {}
                    :execute (fn [_]
                               {:content [(types.text-block "clean output")]
                                :is-error? false})}]
              out (tools.execute-call reg
                                      {:type :tool-call
                                       :id "call-clean"
                                       :name :probe
                                       :arguments {}}
                                      {})
              body (first-text out.message.content)]
          (assert.are.equal "clean output" body)
          (assert.is_nil (string.find body "fen: tool output" 1 true)))))

    (it "marks unknown tool calls as is-error?"
      (fn []
        (let [r (execute registry :no-such-tool nil)]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                          "unknown tool: no%-such%-tool")))))

    (it "passes a fresh {} to execute when args is nil"
      (fn []
        (var seen nil)
        (let [reg [{:name :probe :label "Probe" :description ""
                    :parameters {}
                    :execute (fn [a]
                               (set seen a)
                               {:content [(types.text-block "")] :is-error? false})}]]
          (execute reg :probe nil)
          (assert.are.same {} seen))))

    (it "forwards parsed args directly (provider has already JSON-decoded)"
      (fn []
        (var seen nil)
        (let [reg [{:name :probe :label "Probe" :description ""
                    :parameters {}
                    :execute (fn [a]
                               (set seen a)
                               {:content [(types.text-block "")] :is-error? false})}]]
          (execute reg :probe {:foo :bar :n 7})
          (assert.are.equal :bar seen.foo)
          (assert.are.equal 7 seen.n))))

    (it "passes context to context-aware tools"
      (fn []
        (var seen nil)
        (let [reg [{:name :probe :label "Probe" :description ""
                    :parameters {}
                    :execute (fn [_a ctx]
                               (set seen ctx)
                               {:content [(types.text-block "")] :is-error? false})}]
              ctx {:agent {:model "m"}}]
          (execute reg :probe {} ctx)
          (assert.are.same ctx seen))))

    (it "converts throwing tools to tool error results"
      (fn []
        (let [reg [{:name :boom :label "Boom" :description ""
                    :parameters {}
                    :execute (fn [_] (error "kaboom"))}]
              r (execute reg :boom {})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "kaboom")))))

    (it "runs before-tool hooks and turns vetoes into tool errors"
      (fn []
        (extensions.reset!)
        (let [api (ext-api.make-runtime-api :policy)
              fired {:tool false}
              reg [{:name :probe :label "Probe" :description ""
                    :parameters {}
                    :execute (fn [_]
                               (set fired.tool true)
                               {:content [(types.text-block "ok")]
                                :is-error? false})}]]
          (api.register :hook
                        {:before-tool
                         (fn [name _args _ctx]
                           (when (= name :probe)
                             {:block true :reason "not allowed"}))})
          (let [r (execute reg :probe {})]
            (extensions.reset!)
            (assert.is_true r.is-error?)
            (assert.is_false fired.tool)
            (assert.is_truthy (string.find (first-text r.content)
                                            "not allowed"))))))))

(describe "core.tools.descriptors"
  (fn []
    (it "exposes canonical Tool[] (no execute, no label)"
      (fn []
        (let [descs (tools.descriptors registry)
              names {}]
          (each [_ d (ipairs descs)]
            (assert.is_string d.description)
            (assert.is_table d.parameters)
            (assert.is_nil d.execute)
            (assert.is_nil d.label)
            (tset names (tostring d.name) true))
          (assert.is_true (. names "bash"))
          (assert.is_true (. names "read"))
          (assert.is_true (. names "write"))
          (assert.is_true (. names "ls"))
          (assert.is_true (. names "edit"))
          (assert.is_true (. names "grep"))
          (assert.is_true (. names "find")))))))

