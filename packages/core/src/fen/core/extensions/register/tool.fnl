(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :tool requires {:name ...}"))
  (let [(tagged unregister) (util.add-tagged! state.tools-extra spec owner)]
    (handle-result :tool spec.name owner unregister)))

(fn M.unregister-by-owner [owner]
  (util.remove-where state.tools-extra
                     (fn [t _] (= t.__owner owner))))

(fn M.merged [base]
  "Return base ++ extension-contributed tools."
  (let [out []]
    (each [_ t (ipairs (or base []))] (table.insert out t))
    (each [_ t (ipairs state.tools-extra)] (table.insert out t))
    out))

(fn M.list []
  (let [out []]
    (each [_ t (ipairs state.tools-extra)]
      (table.insert out {:name t.name :owner t.__owner}))
    out))

M
