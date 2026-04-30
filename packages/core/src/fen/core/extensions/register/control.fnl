(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :control requires {:name ...}"))
  (let [record (util.deep-copy spec)]
    (tset record :owner owner)
    (table.insert state.controls-extra record)
    (handle-result :control spec.name owner
      (fn []
        (util.remove-where state.controls-extra (fn [c _] (= c record)))))))

(fn M.unregister-by-owner [owner]
  (util.remove-where state.controls-extra
                     (fn [c _] (= c.owner owner))))

(fn M.list []
  (let [out []]
    (each [_ rec (ipairs state.controls-extra)]
      (table.insert out {:name rec.name :owner rec.owner
                         :description rec.description
                         :keys rec.keys
                         :order rec.order}))
    out))

M
