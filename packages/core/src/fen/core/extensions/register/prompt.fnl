;; System-prompt fragments.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

(fn next-seq! []
  (set state.prompt-next-seq (+ (or state.prompt-next-seq 0) 1))
  state.prompt-next-seq)

(fn order-for [opts]
  (let [raw (or opts.order 90)]
    (or (tonumber raw) 90)))

(fn M.contribute [text-or-fn ?opts owner handle-result]
  (let [opts (or ?opts {})
        entry {:text-or-fn text-or-fn
               :__owner owner
               :id opts.id
               :title opts.title
               :description opts.description
               :order (order-for opts)
               :seq (next-seq!)}]
    (table.insert state.prompt-fragments entry)
    (handle-result :prompt-fragment (or opts.id :prompt) owner
      (fn []
        (util.remove-where state.prompt-fragments (fn [e _] (= e entry)))))))

(fn M.register [spec owner handle-result]
  "Adapter for the kind dispatcher: (register :prompt-fragment {:text ...})."
  (M.contribute (or spec.text (. spec :text-or-fn)) spec owner handle-result))

(fn M.unregister-by-owner [owner]
  (util.remove-where state.prompt-fragments
                     (fn [e _] (= e.__owner owner))))

(fn render-fragment [entry ?ctx]
  (let [val entry.text-or-fn]
    (if (= (type val) :function)
        (let [(ok? result) (pcall val ?ctx)]
          (if ok?
              result
              (.. "<!-- extension "
                  (tostring entry.__owner)
                  " failed: "
                  (tostring result)
                  " -->")))
        val)))

(fn sorted-fragments []
  (let [out []]
    (each [_ entry (ipairs state.prompt-fragments)]
      (table.insert out entry))
    (table.sort out
      (fn [a b]
        (if (= a.order b.order)
            (< a.seq b.seq)
            (< a.order b.order))))
    out))

(fn M.render [?ctx]
  "Render all registered prompt fragments in numeric order. Fragment functions
   receive the prompt context table. Nil/empty fragments are omitted."
  (let [parts []]
    (each [_ entry (ipairs (sorted-fragments))]
      (let [rendered (render-fragment entry ?ctx)]
        (when (and rendered (not= rendered ""))
          (table.insert parts (tostring rendered)))))
    (if (= (length parts) 0)
        nil
        (table.concat parts "\n\n"))))

(fn public-entry [e]
  {:owner e.__owner
   :id e.id
   :title e.title
   :description e.description
   :order e.order
   :seq e.seq
   :dynamic? (= (type e.text-or-fn) :function)})

(fn M.list []
  "Return prompt fragments in final render order."
  (let [out []]
    (each [_ e (ipairs (sorted-fragments))]
      (table.insert out (public-entry e)))
    out))

M
