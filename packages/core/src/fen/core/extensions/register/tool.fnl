(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

;; @doc fen.core.extensions.register.tool.register
;; kind: function
;; signature: (register spec owner handle-result) -> register-result
;; summary: Validate and append an AgentTool contribution so the agent can expose it to providers and execute ToolCalls by name.
;; tags: extensions register tools
(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :tool requires {:name ...}"))
  (when (and spec.exposure
             (not (or (= spec.exposure :always) (= spec.exposure :search))))
    (error "register :tool exposure must be :always or :search"))
  (let [(tagged unregister) (util.add-tagged! state.tools-extra spec owner)]
    (handle-result :tool spec.name owner unregister)))

;; @doc fen.core.extensions.register.tool.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Remove every tool contribution installed by owner from the extension tool registry.
;; tags: extensions register tools reload
(fn M.unregister-by-owner [owner]
  (util.remove-where state.tools-extra
                     (fn [t _] (= t.__owner owner))))

;; @doc fen.core.extensions.register.tool.merged
;; kind: function
;; signature: (merged base) -> [AgentTool]
;; summary: Return base tools followed by extension-contributed tools in registry order for agent-step tool exposure.
;; tags: extensions tools agent
(fn M.merged [base]
  "Return base ++ extension-contributed tools."
  (let [out []]
    (each [_ t (ipairs (or base []))] (table.insert out t))
    (each [_ t (ipairs state.tools-extra)] (table.insert out t))
    out))

;; @doc fen.core.extensions.register.tool.list
;; kind: function
;; signature: (list) -> [ToolInfo]
;; summary: Return lightweight tool metadata for docs and diagnostics without exposing execute functions.
;; tags: extensions tools introspection
(fn M.list []
  (let [out []]
    (each [_ t (ipairs state.tools-extra)]
      (let [rec {:name t.name :owner t.__owner}]
        ;; Keep runtime docs useful without exposing executable callbacks.
        ;; These are the provider-facing fields an operator/model needs when
        ;; deciding how to call a tool.
        (each [_ k (ipairs [:label :snippet :description :parameters :exposure
                            :parallel-safe? :parallel-cap])]
          (when (not= (. t k) nil)
            (tset rec k (. t k))))
        (table.insert out rec)))
    out))

M
