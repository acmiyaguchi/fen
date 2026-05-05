(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :control requires {:name ...}"))
  (let [(record unregister) (util.add-tagged! state.controls-extra spec owner)]
    (handle-result :control spec.name owner unregister)))

(fn M.unregister-by-owner [owner]
  (util.remove-where state.controls-extra
                     (fn [c _] (= c.__owner owner))))

(fn M.list []
  (let [out []]
    (each [_ rec (ipairs state.controls-extra)]
      (table.insert out {:name rec.name :owner rec.__owner
                         :description rec.description
                         :keys rec.keys
                         :order rec.order}))
    out))

M
