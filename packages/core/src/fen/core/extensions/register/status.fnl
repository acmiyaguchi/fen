;; Status item kind. Presenter-neutral blocks composed by active presenters
;; (Waybar/Polybar-style), rather than mutation of one shared status string.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

(fn ensure-store! []
  (when (= state.status-extra nil)
    (set state.status-extra [])))

(fn valid-side? [side]
  (or (= side :left) (= side :right)))

(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :status requires {:name ...}"))
  (when (and spec.side (not (valid-side? spec.side)))
    (error "register :status side must be :left or :right"))
  (when (not= (type spec.render) :function)
    (error "register :status requires {:render fn}"))
  (ensure-store!)
  (let [record (util.deep-copy spec)]
    (tset record :owner owner)
    (when (= record.side nil) (set record.side :left))
    (when (= record.order nil) (set record.order 50))
    (table.insert state.status-extra record)
    (handle-result :status spec.name owner
      (fn []
        (util.remove-where state.status-extra (fn [s _] (= s record)))))))

(fn M.unregister-by-owner [owner]
  (ensure-store!)
  (util.remove-where state.status-extra
                     (fn [s _] (= s.owner owner))))

(fn by-order [a b]
  (let [ao (or a.order 50)
        bo (or b.order 50)]
    (if (not= ao bo) (< ao bo)
        (not= (tostring (or a.owner "")) (tostring (or b.owner "")))
        (< (tostring (or a.owner "")) (tostring (or b.owner "")))
        (< (tostring (or a.name "")) (tostring (or b.name ""))))))

(fn M.list []
  (ensure-store!)
  (let [out []]
    (each [_ rec (ipairs state.status-extra)]
      (table.insert out {:name rec.name
                         :owner rec.owner
                         :side rec.side
                         :order rec.order
                         :render rec.render}))
    (table.sort out by-order)
    out))

M
