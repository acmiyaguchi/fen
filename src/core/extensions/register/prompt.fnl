;; System-prompt fragments.

(local state (require :core.extensions.state))
(local util (require :core.extensions.util))

(local M {})

(set M.SLOTS [:before-body :before-context :end])

(local SLOT-ORDERS {:before-body 25
                    :before-context 45
                    :end 90})

(fn M.slot-valid? [slot]
  (var found false)
  (each [_ s (ipairs M.SLOTS)]
    (when (= s slot) (set found true)))
  found)

(fn next-seq! []
  (set state.prompt-next-seq (+ (or state.prompt-next-seq 0) 1))
  state.prompt-next-seq)

(fn order-for [opts slot]
  (let [raw (or opts.order (. SLOT-ORDERS slot) 90)]
    (or (tonumber raw) 90)))

(fn M.contribute [text-or-fn ?opts owner handle-result]
  (let [opts (or ?opts {})
        slot (or opts.slot :end)]
    (when (not (M.slot-valid? slot))
      (error (.. "prompt: unknown slot " (tostring slot))))
    (let [bucket (. state.prompt-fragments slot)
          entry {:text-or-fn text-or-fn
                 :owner owner
                 :id opts.id
                 :title opts.title
                 :description opts.description
                 :slot slot
                 :order (order-for opts slot)
                 :seq (next-seq!)}]
      (table.insert bucket entry)
      (handle-result :system-prompt-fragment slot owner
        (fn []
          (util.remove-where bucket (fn [e _] (= e entry))))))))

(fn M.register [spec owner handle-result]
  "Adapter for the kind dispatcher: (register :system-prompt {:text ... :slot ...})."
  (M.contribute (or spec.text (. spec :text-or-fn)) spec owner handle-result))

(fn M.unregister-by-owner [owner]
  (each [_ slot (ipairs M.SLOTS)]
    (util.remove-where (. state.prompt-fragments slot)
                       (fn [e _] (= e.owner owner)))))

(fn render-fragment [entry ?ctx]
  (let [val entry.text-or-fn]
    (if (= (type val) :function)
        (let [(ok? result) (pcall val ?ctx)]
          (if ok?
              result
              (.. "<!-- extension "
                  (tostring entry.owner)
                  " failed: "
                  (tostring result)
                  " -->")))
        val)))

(fn collect-fragments []
  (let [out []]
    (each [_ slot (ipairs M.SLOTS)]
      (each [_ entry (ipairs (. state.prompt-fragments slot))]
        (table.insert out entry)))
    out))

(fn sorted-fragments []
  (let [out (collect-fragments)]
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

(fn M.fragments-for [slot]
  "Render registered fragments for one legacy slot, or nil when none render."
  (let [bucket (. state.prompt-fragments slot)]
    (if (or (not bucket) (= (length bucket) 0))
        nil
        (let [parts []]
          (each [_ entry (ipairs bucket)]
            (let [rendered (render-fragment entry)]
              (when (and rendered (not= rendered ""))
                (table.insert parts (tostring rendered)))))
          (if (= (length parts) 0)
              nil
              (table.concat parts "\n\n"))))))

(fn public-entry [e]
  {:owner e.owner
   :id e.id
   :title e.title
   :description e.description
   :slot e.slot
   :order e.order
   :seq e.seq
   :dynamic? (= (type e.text-or-fn) :function)})

(fn M.fragments []
  "Return prompt fragments in final render order. This is the stable
   introspection contract: lower order renders earlier; equal order preserves
   registration sequence."
  (let [out []]
    (each [_ e (ipairs (sorted-fragments))]
      (table.insert out (public-entry e)))
    out))

(fn M.list []
  (M.fragments))

M
