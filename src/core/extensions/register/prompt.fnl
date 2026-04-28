;; System-prompt fragment contributions.

(local state (require :core.extensions.state))
(local util (require :core.extensions.util))

(local M {})

(set M.SLOTS [:before-body :before-context :end])

(fn M.slot-valid? [slot]
  (var found false)
  (each [_ s (ipairs M.SLOTS)]
    (when (= s slot) (set found true)))
  found)

(fn M.contribute [text-or-fn ?opts owner handle-result]
  (let [opts (or ?opts {})
        slot (or opts.slot :end)]
    (when (not (M.slot-valid? slot))
      (error (.. "prompt: unknown slot " (tostring slot))))
    (let [bucket (. state.prompt-fragments slot)
          entry {:text-or-fn text-or-fn :owner owner}]
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

(fn render-fragment [entry]
  (let [val entry.text-or-fn]
    (if (= (type val) :function)
        (let [(ok? result) (pcall val)]
          (if ok?
              result
              (.. "<!-- extension "
                  (tostring entry.owner)
                  " failed: "
                  (tostring result)
                  " -->")))
        val)))

(fn M.fragments-for [slot]
  "Render registered fragments for slot, or nil when none render."
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

(fn M.list []
  (let [out {}]
    (each [_ slot (ipairs M.SLOTS)]
      (let [bucket (. state.prompt-fragments slot)
            entries []]
        (each [_ e (ipairs bucket)]
          (table.insert entries {:owner e.owner
                                 :dynamic? (= (type e.text-or-fn) :function)}))
        (tset out slot entries)))
    out))

M
