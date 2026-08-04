;; Tool-related test cases.

(local ext-api (require :fen.core.extensions.test_api))
(local th (require :fen.testing.tools))
(local tools th.tools)
(local extensions th.extensions)
(local registry th.registry)
(local types th.types)
(local json th.json)
(local extension-state (require :fen.core.extensions.state))
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

    (it "marks restricted tool calls with the policy flag"
      (fn []
        (let [r (execute [{:name :read}] :bash nil
                         {:agent {:tool-restriction
                                  {:flag "--denied-tools"
                                   :restricted-names {:bash true}}}})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                          "tool restricted by %-%-denied%-tools: bash")))))

    (it "keeps unknown calls unknown when a restriction does not name them"
      (fn []
        (let [r (execute [{:name :read}] :grep nil
                         {:agent {:tool-restriction
                                  {:flag "--denied-tools"
                                   :restricted-names {:bash true}}}})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                          "unknown tool: grep" 1 true)))))

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

    (it "rejects invalid arguments before the tool executes"
      (fn []
        (let [called? {:value false}
              reg [{:name :edit :description ""
                    :parameters {:type :object
                                 :properties {:old_string {:type :string}}
                                 :required [:old_string]}
                    :execute (fn [_] (set called?.value true))}]
              r (execute reg :edit {})]
          (assert.is_true r.is-error?)
          (assert.is_false called?.value)
          (assert.is_truthy (string.find (first-text r.content)
                                          "old_string is required" 1 true))
          (assert.are.equal :invalid-arguments r.details.kind)
          (assert.are.equal "old_string" (. r.details.errors 1 :field)))))

    (it "turns malformed schemas into structured tool errors"
      (fn []
        (let [called? {:value false}
              reg [{:name :broken :description ""
                    :parameters "not a schema"
                    :execute (fn [_] (set called?.value true))}]
              r (execute reg :broken {})]
          (assert.is_true r.is-error?)
          (assert.is_false called?.value)
          (assert.are.equal :invalid-tool-schema r.details.kind)
          (assert.are.equal :broken r.details.tool-name)
          (assert.is_truthy (string.find (first-text r.content)
                                          "invalid tool schema" 1 true)))))

    (it "passes valid schema-conforming arguments unchanged"
      (fn []
        (var seen nil)
        (let [reg [{:name :probe :description ""
                    :parameters {:type :object
                                 :properties {:count {:type :integer}}
                                 :required [:count]}
                    :execute (fn [args]
                               (set seen args)
                               {:content [(types.text-block "ok")] :is-error? false})}]
              r (execute reg :probe {:count 2})]
          (assert.is_false r.is-error?)
          (assert.are.same {:count 2} seen))))

    (it "warns once at registration for unknown schema keywords"
      (fn []
        (extensions.reset!)
        (with-tmpdir [dir]
          (set extension-state.log-path (.. dir "/extension-logs.jsonl"))
          (let [api (ext-api.make-runtime-api :schema-extension)]
            (api.register :tool
                          {:name :schema_probe
                           :description ""
                           :parameters {:type :object
                                        :additionalProperties false
                                        :properties {:name {:type :string
                                                            :pattern "^fen$"}}
                                        :required [:name]}
                           :execute (fn [_]
                                      {:content [(types.text-block "ok")]
                                       :is-error? false})})
            (let [reg (extensions.merged-tools [])]
              (execute reg :schema_probe {:name "fen"})
              (execute reg :schema_probe {:name "fen"})
              (assert.are.equal 1 (length extension-state.logs))
              (let [warning (. extension-state.logs 1)
                    details (json.decode warning.msg)]
                (assert.are.equal "warn" warning.level)
                (assert.are.equal "unsupported-json-schema-keywords" details.kind)
                (assert.are.equal "schema_probe" (. details :tool-name))
                (assert.are.equal 2 (length details.keywords))))))
        (extensions.reset!)))

    (it "validates extension-registered tools through the executor"
      (fn []
        (extensions.reset!)
        (let [api (ext-api.make-runtime-api :test-extension)
              called? {:value false}]
          (api.register :tool
                        {:name :extension_probe :description ""
                         :parameters {:type :object
                                      :properties {:enabled {:type :boolean}}
                                      :required [:enabled]}
                         :execute (fn [_] (set called?.value true)
                                    {:content [(types.text-block "ok")]
                                     :is-error? false})})
          (let [r (execute (extensions.merged-tools []) :extension_probe {:enabled "yes"})]
            (extensions.reset!)
            (assert.is_true r.is-error?)
            (assert.is_false called?.value)
            (assert.is_truthy (string.find (first-text r.content)
                                            "enabled must be a boolean" 1 true))))))

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

    (it "allows nil and explicit allow policy decisions for builtin tools"
      (fn []
        (extensions.reset!)
        (let [api (ext-api.make-runtime-api :policy)
              calls {:n 0}
              builtin {:name :builtin-probe :description "" :parameters {}
                       :execute (fn [_] (set calls.n (+ calls.n 1))
                                  {:content [(types.text-block "ok")] :is-error? false})}]
          (api.register :hook {:before-tool (fn [_] nil)})
          (api.register :hook {:before-tool (fn [_] {:allow true})})
          (let [r (execute [builtin] :builtin-probe {})]
            (extensions.reset!)
            (assert.is_false r.is-error?)
            (assert.are.equal 1 calls.n)))))

    (it "passes canonical policy context and blocks extension tools with structured reason"
      (fn []
        (extensions.reset!)
        (var seen nil)
        (let [api (ext-api.make-runtime-api :policy)
              fired {:tool false}]
          (api.register :tool
                        {:name :extension-probe :description "" :parameters {}
                         :execute (fn [_] (set fired.tool true)
                                    {:content [(types.text-block "no")] :is-error? false})})
          (api.register :hook
                        {:before-tool (fn [ctx]
                                        (set seen ctx)
                                        {:block true :reason "extension denied"})})
          (let [r (execute (extensions.merged-tools []) :extension-probe {}
                           {:cwd "/work" :source :model})]
            (extensions.reset!)
            (assert.is_true r.is-error?)
            (assert.is_false fired.tool)
            (assert.are.equal :extension-probe seen.name)
            (assert.are.same {} seen.arguments)
            (assert.are.equal "/work" seen.cwd)
            (assert.are.equal :model seen.source)
            (assert.are.equal :policy-block r.details.kind)
            (assert.are.equal "extension denied" r.details.reason)
            (assert.is_truthy (string.find (first-text r.content)
                                            "extension denied" 1 true))))))

    (it "does not let policy hooks rewrite arguments passed to the tool"
      (fn []
        (extensions.reset!)
        (let [api (ext-api.make-runtime-api :policy)
              args {:value "original"}
              seen {:value nil}
              reg [{:name :probe :description "" :parameters {}
                    :execute (fn [tool-args]
                               (set seen.value tool-args.value)
                               {:content [(types.text-block "ok")] :is-error? false})}]]
          (api.register :hook
                        {:before-tool (fn [ctx]
                                        (set ctx.arguments.value "rewritten")
                                        (set ctx.arguments.added true))})
          (let [r (execute reg :probe args)]
            (extensions.reset!)
            (assert.is_false r.is-error?)
            (assert.are.equal "original" args.value)
            (assert.is_nil args.added)
            (assert.are.equal "original" seen.value)))))

    (it "uses registration order and lets a later policy block win over allows"
      (fn []
        (extensions.reset!)
        (let [api (ext-api.make-runtime-api :policy)
              order []
              reg [{:name :probe :description "" :parameters {}
                    :execute (fn [_] {:content [(types.text-block "ok")] :is-error? false})}]]
          (api.register :hook {:before-tool (fn [_] (table.insert order :first) nil)})
          (api.register :hook {:before-tool (fn [_] (table.insert order :second)
                                               {:block true :reason "second wins"})})
          (api.register :hook {:before-tool (fn [_] (table.insert order :third) nil)})
          (let [r (execute reg :probe {})]
            (extensions.reset!)
            (assert.are.same [:first :second] order)
            (assert.are.equal "second wins" r.details.reason)))))

    (it "fails closed when a policy hook throws before invalid argument validation"
      (fn []
        (extensions.reset!)
        (let [api (ext-api.make-runtime-api :policy)
              fired {:tool false}
              reg [{:name :probe :description ""
                    :parameters {:type :object :required [:required-value]}
                    :execute (fn [_] (set fired.tool true))}]]
          (api.register :hook {:before-tool (fn [_] (error "policy boom"))})
          (let [r (execute reg :probe {})]
            (extensions.reset!)
            (assert.is_true r.is-error?)
            (assert.is_false fired.tool)
            (assert.are.equal :policy-block r.details.kind)
            (assert.is_true r.details.policy-hook-failed?)
            (assert.is_truthy (string.find (first-text r.content)
                                            "policy hook failed" 1 true))
            (assert.is_nil (string.find (first-text r.content)
                                         "invalid arguments" 1 true))))))))

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

