;; Tool-related test cases.

(local th (require :tool_test_helpers))
(local tools th.tools)
(local extensions th.extensions)
(local registry th.registry)
(local types th.types)
(local json th.json)
(local h th.h)
(local read-file th.read-file)
(local first-text th.first-text)
(local execute th.execute)
(local execute-coop th.execute-coop)
(import-macros {: with-tmpdir : with-tmpfile} :test_macros)

(after_each (fn [] (h.assert-no-leaks!)))

(describe "agent_state extension tool"
  (fn []
    (after_each (fn [] (extensions.reset!)))

    (fn agent [reg]
      {:model "test-model"
       :provider-api :openai-completions
       :system-prompt "system text"
       :max-tokens 123
       :api-key "secret"
       :provider-options {:api-key "secret2"}
       :messages [(types.user-message "hello")
                  (types.assistant-message
                    {:content [(types.text-block "hi")]
                     :api :openai-completions
                     :provider :openai
                     :model "test-model"
                     :usage {:input 10 :output 3 :total-tokens 13}
                     :stop-reason :stop})]
       :tools reg})

    (fn agent-state-registry []
      (extensions.reset!)
      (tset package.loaded :fen.extensions.agent_state nil)
      (tset package.loaded :fen.extensions.agent_state.tool nil)
      (require :fen.extensions.agent_state)
      (extensions.merged-tools registry))

    (it "answers simple get queries as JSON"
      (fn []
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:get :model)"}
                               {:agent (agent reg)})]
          (assert.is_false r.is-error?)
          (assert.are.equal "\"test-model\"" (first-text r.content)))))

    (it "supports count, slice, pluck, where, and last"
      (fn []
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:pluck (:slice (:get :messages) -2 2) :role)"}
                               {:agent (agent reg)})
              decoded (json.decode (first-text r.content))]
          (assert.is_false r.is-error?)
          (assert.are.equal "user" (. decoded 1))
          (assert.are.equal "assistant" (. decoded 2)))
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:get (:last (:where (:get :messages) :role :assistant)) :stop-reason)"}
                               {:agent (agent reg)})]
          (assert.is_false r.is-error?)
          (assert.are.equal "\"stop\"" (first-text r.content)))))

    (it "exposes sanitized tool descriptors, not executable closures or secrets"
      (fn []
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:get)"}
                               {:agent (agent reg)})
              text (first-text r.content)]
          (assert.is_false r.is-error?)
          (assert.is_nil (string.find text "secret" 1 true))
          (assert.is_nil (string.find text "execute" 1 true))
          (assert.is_truthy (string.find text "agent_state" 1 true)))))

    (it "exposes extension registry introspection"
      (fn []
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:keys (:get :extensions))"}
                               {:agent (agent reg)})
              decoded (json.decode (first-text r.content))]
          (assert.is_false r.is-error?)
          (assert.are.same ["commands" "event-handlers" "loaded" "presenters" "prompt-fragments" "tools"]
                           decoded))
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:get :extensions :tools 0 :name)"}
                               {:agent (agent reg)})]
          (assert.is_false r.is-error?)
          (assert.are.equal "\"agent_state\"" (first-text r.content)))))

    (it "returns an error for invalid query syntax"
      (fn []
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:get :messages"}
                               {:agent (agent reg)})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "unterminated")))))))

