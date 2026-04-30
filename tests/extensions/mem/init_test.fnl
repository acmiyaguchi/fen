(local extensions (require :core.extensions))

(fn fresh []
  (extensions.reset!)
  (tset package.loaded :extensions.mem nil)
  (tset package.loaded :extensions.mem.state nil)
  (let [seen []]
    (extensions.on :* (fn [ev] (table.insert seen ev)))
    (let [mem (require :extensions.mem)]
      (values seen mem))))

(fn find-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (and (not found) (= ev.type type-key))
      (set found ev)))
  found)

(fn last-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (= ev.type type-key)
      (set found ev)))
  found)

(fn registered? [kind name]
  (var found? false)
  (each [_ rec (ipairs (extensions.list kind))]
    (when (= rec.name name)
      (set found? true)))
  found?)

(describe "extensions.mem"
  (fn []
    (it "registers /mem command and :mem panel"
      (fn []
        (fresh)
        (assert.is_true (registered? :commands :mem))
        (assert.is_true (registered? :panels :mem))))

    (it "/mem toggles panel visibility"
      (fn []
        (let [(seen mem) (fresh)]
          (assert.is_false mem._state.visible?)
          (extensions.dispatch-command "/mem" {})
          (assert.is_true mem._state.visible?)
          (let [ev (last-event seen :info)]
            (assert.is_not_nil ev)
            (assert.is_not_nil (string.find ev.text "mem panel: on" 1 true)))
          (extensions.dispatch-command "/mem" {})
          (assert.is_false mem._state.visible?)
          (let [ev (last-event seen :info)]
            (assert.is_not_nil (string.find ev.text "mem panel: off" 1 true))))))

    (it "/mem on and /mem off are explicit"
      (fn []
        (let [(_ mem) (fresh)]
          (extensions.dispatch-command "/mem off" {})
          (assert.is_false mem._state.visible?)
          (extensions.dispatch-command "/mem on" {})
          (assert.is_true mem._state.visible?)
          (extensions.dispatch-command "/mem on" {})
          (assert.is_true mem._state.visible?))))

    (it "/mem gc emits a one-line GC summary and does not toggle"
      (fn []
        (let [(seen mem) (fresh)]
          (set mem._state.visible? false)
          (extensions.dispatch-command "/mem gc" {})
          (assert.is_false mem._state.visible?)
          (let [ev (last-event seen :info)]
            (assert.is_not_nil ev)
            (assert.is_not_nil (string.find ev.text "mem gc:" 1 true))
            (assert.is_not_nil (string.find ev.text "collected" 1 true))))))

    (it "panel height is 0 when hidden and >0 when visible"
      (fn []
        (let [(_ mem) (fresh)
              spec (mem.panel-spec)]
          (set mem._state.visible? false)
          (assert.are.equal 0 (spec.height {:w 80}))
          (set mem._state.visible? true)
          (assert.is_true (> (spec.height {:w 80}) 0)))))

    (it "panel render returns row list when visible, empty when hidden"
      (fn []
        (let [(_ mem) (fresh)
              spec (mem.panel-spec)]
          (set mem._state.visible? false)
          (assert.are.equal 0 (length (spec.render {:w 80})))
          (set mem._state.visible? true)
          (let [rows (spec.render {:w 80})]
            (assert.is_true (> (length rows) 0))
            (var saw-memory? false)
            (var saw-registries? false)
            (each [_ r (ipairs rows)]
              (when (string.find r.text "Memory" 1 true)
                (set saw-memory? true))
              (when (string.find r.text "Registries" 1 true)
                (set saw-registries? true)))
            (assert.is_true saw-memory?)
            (assert.is_true saw-registries?)))))

    (it "panel includes App rows when run-state is cached"
      (fn []
        (let [(_ mem) (fresh)
              spec (mem.panel-spec)]
          (extensions.dispatch-command
            "/mem on"
            {:agent {:messages ["a" "b" "c"]}
             :session {:id "s1" :path "/tmp/s.jsonl"}})
          (let [rows (spec.render {:w 80})]
            (var found-msgs? false)
            (var found-session? false)
            (each [_ r (ipairs rows)]
              (when (string.find r.text "messages: 3" 1 true)
                (set found-msgs? true))
              (when (string.find r.text "session path: /tmp/s.jsonl" 1 true)
                (set found-session? true)))
            (assert.is_true found-msgs?)
            (assert.is_true found-session?)))))

    (it "report-rows returns memory and registry rows"
      (fn []
        (let [(_ mem) (fresh)
              rows (mem.report-rows nil {:gc? false})]
          (var saw-memory? false)
          (var saw-registries? false)
          (var saw-lua-heap? false)
          (each [_ r (ipairs rows)]
            (when (= r.text "Memory") (set saw-memory? true))
            (when (= r.text "Registries") (set saw-registries? true))
            (when (string.find r.text "lua heap:" 1 true)
              (set saw-lua-heap? true)))
          (assert.is_true saw-memory?)
          (assert.is_true saw-registries?)
          (assert.is_true saw-lua-heap?))))

    (it "report-rows with gc? splits before/after heap"
      (fn []
        (let [(_ mem) (fresh)
              rows (mem.report-rows nil {:gc? true})]
          (var saw-before? false)
          (var saw-after? false)
          (var saw-collected? false)
          (each [_ r (ipairs rows)]
            (when (string.find r.text "lua heap before GC" 1 true)
              (set saw-before? true))
            (when (string.find r.text "lua heap after GC" 1 true)
              (set saw-after? true))
            (when (string.find r.text "collected:" 1 true)
              (set saw-collected? true)))
          (assert.is_true saw-before?)
          (assert.is_true saw-after?)
          (assert.is_true saw-collected?))))

    (it ":dismiss closes the panel when visible"
      (fn []
        (let [(seen mem) (fresh)]
          (extensions.dispatch-command "/mem on" {})
          (assert.is_true mem._state.visible?)
          (extensions.emit {:type :dismiss})
          (assert.is_false mem._state.visible?)
          (let [ev (last-event seen :info)]
            (assert.is_not_nil (string.find ev.text "mem panel: off" 1 true))))))

    (it ":dismiss is a no-op when the panel is hidden"
      (fn []
        (let [(seen mem) (fresh)]
          (assert.is_false mem._state.visible?)
          (let [info-before (length (icollect [_ ev (ipairs seen)]
                                      (when (= ev.type :info) ev)))]
            (extensions.emit {:type :dismiss})
            (assert.is_false mem._state.visible?)
            (let [info-after (length (icollect [_ ev (ipairs seen)]
                                       (when (= ev.type :info) ev)))]
              (assert.are.equal info-before info-after))))))

    (it "samples grow on :llm-end events"
      (fn []
        (let [(_ mem) (fresh)
              before (length mem._state.samples)]
          (extensions.emit {:type :llm-end})
          (extensions.emit {:type :llm-end})
          (assert.are.equal (+ before 2) (length mem._state.samples)))))))
