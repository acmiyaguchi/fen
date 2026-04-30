;; Panel item kind. Bounded vertical region rendered by the active presenter
;; into a semantic placement (e.g. :below-status, :above-input). Mirrors the
;; :status kind but contributes a row list rather than a single inline text.
;;
;; v1 placements: :below-status (anchor = status bar; lower :order = closer
;; to top) and :above-input (anchor = input row; lower :order = closer to
;; input).
;;
;; v1 spec shape:
;;   {:name      <identifier>          ; required
;;    :placement :below-status|:above-input
;;    :order     <number>               ; default 50
;;    :height    (fn [ctx] <int>)       ; required; 0 = hidden this frame
;;    :render    (fn [ctx] [<row>...])} ; required
;;
;; A row is `{:text str :attr semantic-style ?:segments [...]}`. The
;; presenter owns geometry, error isolation, and final styling.

(local state (require :core.extensions.state))
(local util (require :core.extensions.util))

(local M {})

(fn ensure-store! []
  (when (= state.panel-extra nil)
    (set state.panel-extra [])))

(fn valid-placement? [p]
  (or (= p :below-status) (= p :above-input)))

(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :panel requires {:name ...}"))
  (when (and spec.placement (not (valid-placement? spec.placement)))
    (error "register :panel placement must be :below-status or :above-input"))
  (when (not= (type spec.render) :function)
    (error "register :panel requires {:render fn}"))
  (when (not= (type spec.height) :function)
    (error "register :panel requires {:height fn}"))
  (ensure-store!)
  (let [record (util.deep-copy spec)]
    (tset record :owner owner)
    (when (= record.placement nil) (set record.placement :above-input))
    (when (= record.order nil) (set record.order 50))
    (table.insert state.panel-extra record)
    (handle-result :panel spec.name owner
      (fn []
        (util.remove-where state.panel-extra (fn [p _] (= p record)))))))

(fn M.unregister-by-owner [owner]
  (ensure-store!)
  (util.remove-where state.panel-extra
                     (fn [p _] (= p.owner owner))))

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
    (each [_ rec (ipairs state.panel-extra)]
      (table.insert out {:name rec.name
                         :owner rec.owner
                         :placement rec.placement
                         :order rec.order
                         :height rec.height
                         :render rec.render}))
    (table.sort out by-order)
    out))

M
