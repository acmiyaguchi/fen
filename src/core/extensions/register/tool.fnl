(local state (require :core.extensions.state))
(local util (require :core.extensions.util))

(local M {})

(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :tool requires {:name ...}"))
  (let [tagged (util.deep-copy spec)]
    (tset tagged :__owner owner)
    (table.insert state.tools-extra tagged)
    (handle-result :tool spec.name owner
      (fn []
        (util.remove-where state.tools-extra (fn [t _] (= t tagged)))))))

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
