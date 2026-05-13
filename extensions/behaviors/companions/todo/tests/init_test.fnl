(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local register-registry (require :fen.core.extensions.register))
(local command-registry (require :fen.core.extensions.register.command))
(local tool-registry (require :fen.core.extensions.register.tool))
(local tools (require :fen.core.tools))

(fn fresh []
  (test-api.reset!)
  (tset package.loaded :fen.extensions.todo nil)
  (tset package.loaded :fen.extensions.todo.state nil)
  (let [seen []]
    (events.on :* (fn [ev] (table.insert seen ev)))
    (let [todo (require :fen.extensions.todo)
          api (test-api.make-runtime-api :todo)]
      (todo.register api)
      (values seen todo api))))

(fn registered? [kind name]
  (var found? false)
  (each [_ rec (ipairs (register-registry.list kind))]
    (when (= rec.name name)
      (set found? true)))
  found?)

(fn first-text [content]
  (let [b (. content 1)]
    (if (and b (= b.type :text)) b.text "")))

(fn execute-tool [args]
  (let [reg (tool-registry.merged [])
        out (tools.execute-call reg
                                {:type :tool-call
                                 :id "call-1"
                                 :name :todo_write
                                 :arguments args}
                                {})]
    out.result))

(fn status-spec []
  (var found nil)
  (each [_ rec (ipairs (register-registry.list :status))]
    (when (= rec.name :todo)
      (set found rec)))
  found)

(fn panel-spec []
  (var found nil)
  (each [_ rec (ipairs (register-registry.list :panels))]
    (when (= rec.name :todo)
      (set found rec)))
  found)

(fn snapshot []
  (. (register-registry.collect-introspection :todo nil) :todo :state))

(fn last-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (= ev.type type-key)
      (set found ev)))
  found)

(fn saw-event? [seen type-key]
  (var found? false)
  (each [_ ev (ipairs seen)]
    (when (= ev.type type-key)
      (set found? true)))
  found?)

(describe "extensions.todo"
  (fn []
    (after_each (fn [] (test-api.reset!)))

    (it "registers tool, command, panel, status, prompt, and introspection"
      (fn []
        (let [(_seen _todo api) (fresh)]
          (assert.is_true (registered? :tools :todo_write))
          (assert.is_true (registered? :commands :todos))
          (assert.is_true (registered? :panels :todo))
          (assert.is_true (registered? :status :todo))
          (assert.is_true (registered? :introspectors :state))
          (let [frags (api.list :prompt-fragments)]
            (assert.are.equal :todo-guidance (. frags 1 :id))))))

    (it "todo_write overwrites state and returns readable text plus details"
      (fn []
        (let [(_seen todo) (fresh)
              result (execute-tool {:items [{:text "Inspect APIs" :status "completed"}
                                            {:text "Write tests" :status "in_progress"}
                                            {:text "Run checks" :status "pending"}]})]
          (assert.is_false result.is-error?)
          (assert.are.equal 3 (length todo._state.items))
          (assert.are.equal "Write tests" (. todo._state.items 2 :text))
          (assert.are.equal "in_progress" (. todo._state.items 2 :status))
          (assert.are.equal 3 (length result.details.items))
          (assert.are.equal todo._state.version result.details.version)
          (assert.is_truthy (string.find (first-text result.content) "todo: 1/3" 1 true))
          (assert.is_truthy (string.find (first-text result.content) "[~] Write tests" 1 true)))))

    (it "todo_write with empty items clears the list"
      (fn []
        (let [(_seen todo) (fresh)]
          (execute-tool {:items [{:text "One" :status "pending"}]})
          (assert.are.equal 1 (length todo._state.items))
          (let [result (execute-tool {:items []})]
            (assert.is_false result.is-error?)
            (assert.are.equal 0 (length todo._state.items))
            (assert.are.equal "Todo list cleared." (first-text result.content))))))

    (it "validates item shape, statuses, and single active item"
      (fn []
        (fresh)
        (let [r (execute-tool {})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "items must be an array" 1 true)))
        (let [r (execute-tool {:items [{:text "x" :status "blocked"}]})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "status" 1 true)))
        (let [r (execute-tool {:items [{:text "" :status "pending"}]})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "non-empty" 1 true)))
        (let [r (execute-tool {:items [{:text "a" :status "in_progress"}
                                      {:text "b" :status "in_progress"}]})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "only one" 1 true)))))

    (it "validates item count, text length, and sparse arrays"
      (fn []
        (fresh)
        (let [many []]
          (for [i 1 51]
            (table.insert many {:text (.. "item " i) :status "pending"}))
          (let [r (execute-tool {:items many})]
            (assert.is_true r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "at most 50" 1 true))))
        (let [r (execute-tool {:items [{:text (string.rep "x" 241)
                                       :status "pending"}]})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "240 bytes" 1 true)))
        (let [sparse []]
          (tset sparse 2 {:text "gap" :status "pending"})
          (let [r (execute-tool {:items sparse})]
            (assert.is_true r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "array" 1 true))))))

    (it "/todos toggles the panel and :dismiss closes it"
      (fn []
        (let [(seen todo) (fresh)]
          (assert.is_false todo._state.visible?)
          (command-registry.dispatch "/todos" {})
          (assert.is_true todo._state.visible?)
          (assert.is_true (saw-event? seen :dismiss))
          (assert.is_truthy (string.find (. (last-event seen :info) :text) "on" 1 true))
          (events.emit {:type :dismiss})
          (assert.is_false todo._state.visible?))))

    (it "/todos show prints without toggling panel visibility"
      (fn []
        (let [(seen todo) (fresh)]
          (execute-tool {:items [{:text "Show me" :status "pending"}]})
          (set todo._state.visible? false)
          (command-registry.dispatch "/todos show" {})
          (assert.is_false todo._state.visible?)
          (let [ev (last-event seen :assistant-text)]
            (assert.is_not_nil ev)
            (assert.is_truthy (string.find ev.text "Show me" 1 true))))))

    (it "panel renders rows only when visible"
      (fn []
        (let [(_seen todo) (fresh)
              p (panel-spec)]
          (execute-tool {:items [{:text "Panel item" :status "pending"}]})
          (assert.are.equal 0 (p.height {:w 80}))
          (set todo._state.visible? true)
          (assert.is_true (> (p.height {:w 80}) 0))
          (let [rows (p.render {:w 80})]
            (assert.is_true (> (length rows) 0))
            (var found? false)
            (each [_ row (ipairs rows)]
              (when (string.find row.text "Panel item" 1 true)
                (set found? true)))
            (assert.is_true found?)))))

    (it "status item is hidden when empty and shows completed over total"
      (fn []
        (fresh)
        (let [s (status-spec)]
          (assert.is_nil (s.render {}))
          (execute-tool {:items [{:text "Done" :status "completed"}
                                {:text "Todo" :status "pending"}]})
          (let [r (s.render {})]
            (assert.are.equal "todo:1/2" r.text)))))

    (it "introspection returns counts and visibility"
      (fn []
        (let [(_seen todo) (fresh)]
          (execute-tool {:items [{:text "Done" :status "completed"}
                                {:text "Active" :status "in_progress"}
                                {:text "Later" :status "pending"}]})
          (set todo._state.visible? true)
          (let [snap (snapshot)]
            (assert.are.equal 3 snap.count)
            (assert.are.equal 1 snap.pending)
            (assert.are.equal 1 (. snap :in-progress))
            (assert.are.equal 1 snap.completed)
            (assert.are.equal "Active" (. snap.items 2 :text))
            (assert.is_true snap.visible?)))))

    (it "rebuilds from the latest todo_write tool-result on agent-started"
      (fn []
        (let [(_seen todo) (fresh)]
          (events.emit {:type :agent-started
                        :agent {:messages [{:role :tool-result
                                            :tool-name :todo_write
                                            :details {:items [{:text "Old" :status "completed"}]
                                                      :version 2}}
                                           {:role :tool-result
                                            :tool-name :todo_write
                                            :details {:items [{:text "Latest" :status "pending"}]
                                                      :version 3}}]}})
          (assert.are.equal 1 (length todo._state.items))
          (assert.are.equal "Latest" (. todo._state.items 1 :text))
          (assert.are.equal 3 todo._state.version))))

    (it "reset clears state and replayed tool-result events repopulate it"
      (fn []
        (let [(_seen todo) (fresh)]
          (execute-tool {:items [{:text "Before" :status "pending"}]})
          (events.emit {:type :reset-conversation})
          (assert.are.equal 0 (length todo._state.items))
          (events.emit {:type :tool-result
                        :name :todo_write
                        :result {:details {:items [{:text "Replayed" :status "completed"}]
                                           :version 7}}})
          (assert.are.equal 1 (length todo._state.items))
          (assert.are.equal "Replayed" (. todo._state.items 1 :text))
          (assert.are.equal 7 todo._state.version))))))
