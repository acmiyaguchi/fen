;; Tool-related test cases.

(local ext-api (require :fen.core.extensions.test_api))
(local th (require :fen.testing.tools))
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
(import-macros {: with-tmpdir : with-tmpfile} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(describe "agent_state extension tool"
  (fn []
    (after_each (fn [] (extensions.reset!)))

    (fn agent [reg]
      {:model "test-model"
       :provider-name :openai
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
      (let [mod (require :fen.extensions.agent_state)
            api (ext-api.make-runtime-api :agent_state)]
        (mod.register api))
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
          (assert.are.same ["commands" "event-handlers" "loaded" "panels" "presenters" "prompt-fragments" "tools"]
                           decoded))
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:get :extensions :tools 0 :name)"}
                               {:agent (agent reg)})]
          (assert.is_false r.is-error?)
          (assert.are.equal "\"agent_state\"" (first-text r.content)))))

    (it "exposes panel visibility introspection"
      (fn []
        (let [reg (agent-state-registry)
              api (ext-api.make-runtime-api :panel-test)]
          (api.register :panel
            {:name :visible-panel
             :placement :above-input
             :order 10
             :height (fn [_ctx] 2)
             :render (fn [_ctx] [])})
          (api.register :panel
            {:name :hidden-panel
             :placement :above-input
             :order 20
             :height (fn [_ctx] 0)
             :render (fn [_ctx] [])})
          (let [r (execute reg :agent_state
                           {:query "(:get :extensions :panels)"}
                           {:agent (agent reg)})
                decoded (json.decode (first-text r.content))]
            (assert.is_false r.is-error?)
            (assert.are.equal "visible-panel" (. decoded 1 :name))
            (assert.are.equal true (. decoded 1 "visible?"))
            (assert.are.equal 2 (. decoded 1 :height))
            (assert.are.equal "hidden-panel" (. decoded 2 :name))
            (assert.are.equal false (. decoded 2 "visible?"))))))

    (it "exposes recent errors and the append log path"
      (fn []
        (let [reg (agent-state-registry)]
          (extensions.emit {:type :error
                            :error "inline boom"
                            :traceback "stack traceback\n  here"})
          (let [r (execute reg :agent_state
                           {:query "(:get :errors -1 :error)"}
                           {:agent (agent reg)})]
            (assert.is_false r.is-error?)
            (assert.are.equal "\"inline boom\"" (first-text r.content)))
          (let [r (execute reg :agent_state
                           {:query "(:get :error-log-path)"}
                           {:agent (agent reg)})
                text (first-text r.content)]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find text "errors.jsonl" 1 true))))))

    (it "returns an error for invalid query syntax"
      (fn []
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:get :messages"}
                               {:agent (agent reg)})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "unterminated")))))))

