(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))
(local contrib (require :fen.core.extensions.contrib))
(local json-schema (require :fen.util.json_schema))
(local logs (require :fen.core.extensions.logs))

(local M {})

;; @doc fen.core.extensions.register.tool.register
;; kind: function
;; signature: (register spec owner handle-result) -> register-result
;; summary: Validate (a :name and an :execute function) and add an AgentTool contribution so the agent can expose it to providers and execute ToolCalls by name.
;; tags: extensions register tools
(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :tool requires {:name ...}"))
  (when (not= (type spec.execute) :function)
    (error "register :tool requires {:execute fn}"))
  (when (and spec.exposure
             (not (or (= spec.exposure :always) (= spec.exposure :search))))
    (error "register :tool exposure must be :always or :search"))
  (let [unsupported (json-schema.unsupported-keywords (?. spec :parameters))]
    (when (> (length unsupported) 0)
      ;; Warn once at registration; the validator ignores unknown keywords rather than failing every call.
      (logs.record! owner :warn
                    {:kind :unsupported-json-schema-keywords
                     :tool-name spec.name
                     :keywords unsupported})))
  (let [(_record unregister) (contrib.add! owner :tools nil
                                           (util.deep-copy spec))]
    (handle-result :tool spec.name owner unregister)))

;; @doc fen.core.extensions.register.tool.merged
;; kind: function
;; signature: (merged base) -> [AgentTool]
;; summary: Return base ++ extension tools in canonical order (by name; equal names keep fold order, so the first is the earliest owner), independent of registration and reload order (#622).
;; tags: extensions register tools
(fn M.merged [base]
  (let [out []
        pos {}]
    (each [_ t (ipairs (or base []))]
      (table.insert out t))
    (each [_ t (ipairs state.tools-extra)]
      (table.insert out t))
    (each [i t (ipairs out)]
      (tset pos t i))
    (table.sort out
                (fn [a b]
                  (let [an (tostring a.name)
                        bn (tostring b.name)]
                    (if (= an bn) (< (. pos a) (. pos b)) (< an bn)))))
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
        (each [_ k (ipairs [:label
                            :snippet
                            :description
                            :parameters
                            :exposure
                            :parallel-safe?
                            :parallel-cap])]
          (when (not= (. t k) nil)
            (tset rec k (. t k))))
        (table.insert out rec)))
    out))

M
