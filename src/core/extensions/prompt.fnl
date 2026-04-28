(local state (require :core.extensions.state))
(local util (require :core.extensions.util))

(local M {})
(set M.PROMPT-SLOTS [:before-body :before-context :end])

(fn M.slot-valid? [slot]
  (var found false)
  (each [_ s (ipairs M.PROMPT-SLOTS)]
    (when (= s slot) (set found true)))
  found)

(fn handle-result [kind name owner unregister]
  {: kind : name : owner : unregister})

(fn M.contribute [text-or-fn ?opts owner]
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

M
