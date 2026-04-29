(local extensions (require :core.extensions))

(fn fresh []
  (extensions.reset!)
  (tset package.loaded :extensions.mem nil)
  (tset package.loaded :extensions.mem.state nil)
  (let [seen []]
    (extensions.on :* (fn [ev] (table.insert seen ev)))
    (require :extensions.mem)
    seen))

(fn find-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (and (not found) (= ev.type type-key))
      (set found ev)))
  found)

(describe "extensions.mem"
  (fn []
    (it "registers /mem"
      (fn []
        (fresh)
        (let [commands (extensions.list :commands)]
          (var found? false)
          (each [_ c (ipairs commands)]
            (when (= c.name :mem)
              (set found? true)))
          (assert.is_true found?))))

    (it "/mem emits memory diagnostics"
      (fn []
        (let [seen (fresh)]
          (extensions.dispatch-command "/mem" {:agent {:messages ["a" "b"]}
                                               :session {:id "s1" :path "/tmp/s.jsonl"}})
          (let [ev (find-event seen :assistant-text)]
            (assert.is_not_nil ev)
            (assert.is_not_nil (string.find ev.text "Memory" 1 true))
            (assert.is_not_nil (string.find ev.text "lua heap:" 1 true))
            (assert.is_not_nil (string.find ev.text "messages: 2" 1 true))
            (assert.is_not_nil (string.find ev.text "session path: /tmp/s.jsonl" 1 true))
            (assert.is_not_nil (string.find ev.text "Registries" 1 true))))))

    (it "/mem gc collects and reports before/after heap"
      (fn []
        (let [seen (fresh)]
          (extensions.dispatch-command "/mem gc" {})
          (let [ev (find-event seen :assistant-text)]
            (assert.is_not_nil ev)
            (assert.is_not_nil (string.find ev.text "lua heap before GC" 1 true))
            (assert.is_not_nil (string.find ev.text "lua heap after GC" 1 true))
            (assert.is_not_nil (string.find ev.text "collected:" 1 true))))))

    (it "keeps a small sample history"
      (fn []
        (let [seen (fresh)]
          (extensions.dispatch-command "/mem" {})
          (extensions.dispatch-command "/mem" {})
          (let [ev (. seen (length seen))]
            (assert.are.equal :assistant-text ev.type)
            (assert.is_not_nil (string.find ev.text "History" 1 true))
            (assert.is_not_nil (string.find ev.text "[#" 1 true))))))))
