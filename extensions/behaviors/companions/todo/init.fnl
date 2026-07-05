;; Structured todo companion extension.
;;
;; `todo_write` is a model-facing full-overwrite tool. The current list is
;; mirrored in reload-safe extension state for the panel/status, and persisted
;; in the canonical tool-result `:details` payload so --continue can rebuild
;; state by scanning transcript history.

(local types (require :fen.core.types))
(local state (require :fen.extensions.todo.state))

(local M {})
(local MAX-ITEMS 50)
(local MAX-TEXT-BYTES 240)
(local VALID-STATUS {:pending true
                     :in_progress true
                     :completed true})

(local PROMPT
  (table.concat
    ["Use the todo_write tool to track non-trivial multi-step work."
     "Keep the list short and current; overwrite the full list whenever tasks are added, reordered, started, or completed."
     "Use statuses pending, in_progress, and completed, with at most one in_progress item."
     "Do not call todo_write for trivial one-step requests."
     "When the work is finished, mark every item completed or clear the list with an empty items array."]
    "\n"))

(local text-util (require :fen.util.text))
(local trim (. text-util :trim))
(local truncate-line (. text-util :truncate-line))
(local first-arg (. (require :fen.util.args) :first-arg))

(fn status-string [s]
  (let [v (tostring (or s ""))]
    ;; Be tolerant of Fennel keyword-looking strings in synthetic tests.
    (or (string.match v "^:(.+)$") v)))

(fn array? [xs]
  (if (not= (type xs) :table)
      false
      (let [n (length xs)]
        (var ok? true)
        (each [k _ (pairs xs)]
          (when (not (and (= (type k) :number)
                          (= k (math.floor k))
                          (>= k 1)
                          (<= k n)))
            (set ok? false)))
        ok?)))

(fn copy-items [items]
  (let [out []]
    (each [_ item (ipairs (or items []))]
      (table.insert out {:text item.text :status item.status}))
    out))

(fn counts [?items]
  (let [items (or ?items state.items)
        c {:total (length (or items []))
           :pending 0
           :in-progress 0
           :completed 0}]
    (each [_ item (ipairs (or items []))]
      (let [s (status-string item.status)]
        (if (= s "pending")
            (set c.pending (+ c.pending 1))
            (= s "in_progress")
            (tset c :in-progress (+ (or (. c :in-progress) 0) 1))
            (= s "completed")
            (set c.completed (+ c.completed 1)))))
    c))

(fn invalidate-cache! []
  (set state.cached-rows nil)
  (set state.cached-w 0)
  (set state.cached-version -1))

(fn set-items! [items ?version]
  (set state.items (copy-items items))
  (set state.version (or ?version (+ (or state.version 0) 1)))
  (set state.last-updated (os.time))
  (invalidate-cache!))

(fn clear! []
  (set-items! [] (+ (or state.version 0) 1)))

(fn validate-items [items]
  (if (not (array? items))
      (values nil "items must be an array")
      (> (length items) MAX-ITEMS)
      (values nil (.. "items must contain at most " MAX-ITEMS " entries"))
      (let [out []
            in-progress []]
        (var err nil)
        (each [i item (ipairs items)]
          (when (not err)
            (if (not= (type item) :table)
                (set err (.. "items[" i "] must be an object"))
                (if (not= (type item.text) :string)
                    (set err (.. "items[" i "].text must be a non-empty string"))
                    (not= (type item.status) :string)
                    (set err (.. "items[" i "].status must be pending, in_progress, or completed"))
                    (let [text (trim item.text)
                          status (status-string item.status)]
                      (if (= text "")
                          (set err (.. "items[" i "].text must be a non-empty string"))
                          (> (length text) MAX-TEXT-BYTES)
                          (set err (.. "items[" i "].text must be at most " MAX-TEXT-BYTES " bytes after trimming"))
                          (not (. VALID-STATUS status))
                          (set err (.. "items[" i "].status must be pending, in_progress, or completed"))
                          (do
                            (when (= status "in_progress")
                              (table.insert in-progress i))
                            (table.insert out {:text text :status status}))))))))
        (if err
            (values nil err)
            (> (length in-progress) 1)
            (values nil "only one todo item may be in_progress")
            (values out nil)))))

(fn result [text is-error? ?details]
  (let [r {:content [(types.text-block (or text ""))]
           :is-error? (or is-error? false)}]
    (when (not= ?details nil)
      (set r.details ?details))
    r))

(fn err [message]
  (result (.. "error: " (tostring message)) true))

(fn status-mark [status]
  (let [s (status-string status)]
    (if (= s "completed") "[x]"
        (= s "in_progress") "[~]"
        "[ ]")))

(fn summary-line [?items]
  (let [c (counts ?items)]
    (if (= c.total 0)
        "todo: empty"
        (.. "todo: " c.completed "/" c.total
            (if (> (or (. c :in-progress) 0) 0) " (1 active)" "")))))

(fn render-text [items]
  (if (= (length items) 0)
      "Todo list cleared."
      (let [lines [(summary-line items)]]
        (each [_ item (ipairs items)]
          (table.insert lines (.. (status-mark item.status) " " item.text)))
        (table.concat lines "\n"))))

(fn execute [args _ctx]
  (let [(items validation-error) (validate-items (?. args :items))]
    (if validation-error
        (err validation-error)
        (do
          (set-items! items)
          (result (render-text state.items)
                  false
                  {:items (copy-items state.items)
                   :version state.version})))))

(fn adopt-details! [details]
  (when (and details details.items)
    (let [(items validation-error) (validate-items details.items)]
      (when (not validation-error)
        (set-items! items details.version)
        true))))

(fn rebuild-from-messages! [messages]
  (var latest nil)
  (each [_ m (ipairs (or messages []))]
    (when (and (= m.role :tool-result)
               (= (tostring m.tool-name) "todo_write")
               (?. m :details :items))
      (set latest m.details)))
  (if latest
      (adopt-details! latest)
      (set-items! [] 0)))

(fn dim [text] {:text text :style :dim})
(fn heading [text] {:text text :style :assistant})

(fn todo-rows []
  (let [rows [(heading "Todos")
              (dim (.. "  " (summary-line state.items)))] ]
    (if (= (length state.items) 0)
        (table.insert rows (dim "  (empty)"))
        (each [i item (ipairs state.items)]
          (table.insert rows
                        (dim (.. "  " i ". "
                                 (status-mark item.status) " "
                                 (truncate-line item.text 96))))))
    rows))

(fn box-top [w title]
  (let [head (.. "┌─ " title " ")
        head-cols (+ 4 (length title))
        fill-cols (math.max 0 (- w head-cols 1))]
    (.. head (string.rep "─" fill-cols) "┐")))

(fn box-bottom [w]
  (.. "└" (string.rep "─" (math.max 0 (- w 2))) "┘"))

(fn box-side [w text]
  (let [inner-w (math.max 0 (- w 4))
        text (or text "")
        clipped (if (> (length text) inner-w) (string.sub text 1 inner-w) text)
        pad (math.max 0 (- inner-w (length clipped)))]
    (.. "│ " clipped (string.rep " " pad) " │")))

(fn bordered-rows [w content]
  (let [out [{:text (box-top w "todos") :style :dim}]]
    (each [_ row (ipairs content)]
      (table.insert out {:text (box-side w row.text) :style row.style}))
    (table.insert out {:text (box-bottom w) :style :dim})
    out))

(fn panel-rows [w]
  (when (or (not state.cached-rows)
            (not= state.cached-w w)
            (not= state.cached-version state.version))
    (set state.cached-rows (bordered-rows w (todo-rows)))
    (set state.cached-w w)
    (set state.cached-version state.version))
  state.cached-rows)

(fn panel-spec []
  {:name :todo
   :placement :above-input
   :order 35
   :height (fn [ctx]
             (if state.visible?
                 (length (panel-rows (or (?. ctx :w) 80)))
                 0))
   :render (fn [ctx]
             (if state.visible?
                 (panel-rows (or (?. ctx :w) 80))
                 []))})

(fn set-visible! [api visible? announce?]
  (when (and visible? (not state.visible?))
    (api.emit {:type :dismiss}))
  (set state.visible? visible?)
  (invalidate-cache!)
  (when announce?
    (api.emit {:type :info
               :text (if visible?
                         "todos panel: on (/todos off or /todos to hide)"
                         "todos panel: off")})))

(fn handle-command [api args]
  (let [arg (first-arg args)
        kw (and arg (string.lower arg))]
    (if (= kw "on")
        (set-visible! api true true)
        (= kw "off")
        (set-visible! api false true)
        (= kw "show")
        (api.emit {:type :assistant-text :text (render-text state.items)})
        (set-visible! api (not state.visible?) true))))

(fn status-render [_ctx]
  (let [c (counts)]
    (when (> c.total 0)
      {:text (.. "todo:" c.completed "/" c.total)
       :style :status})))

(fn snapshot [_ctx]
  (let [c (counts)]
    {:count c.total
     :pending c.pending
     :in-progress (. c :in-progress)
     :completed c.completed
     :items (copy-items state.items)
     :visible? state.visible?
     :version state.version
     :last-updated state.last-updated}))

(fn register! [api]
  (api.prompt PROMPT {:id :todo-guidance
                      :title "Todo guidance"
                      :description "Guidance for using todo_write on multi-step work"
                      :order 70})
  (api.register :tool
    {:name :todo_write
     :label "Todo Write"
     :snippet "Update the structured todo list"
     :description "Create or update the structured todo list for this session. Use for non-trivial multi-step work. This tool overwrites the full current list; provide every item that should remain. Status must be pending, in_progress, or completed, with at most one in_progress item. Use an empty items array to clear the list."
     :parameters {:type :object
                  :properties {:items {:type :array
                                       :description "Complete todo list to store. This overwrites any previous list."
                                       :items {:type :object
                                               :properties {:text {:type :string
                                                                  :description "Short task description"}
                                                            :status {:type :string
                                                                     :enum ["pending" "in_progress" "completed"]}}
                                               :required [:text :status]}}}
                  :required [:items]}
     :execute execute})
  (api.register :command
    {:name :todos
     :order 55
     :description "Toggle the todo panel; /todos show prints the current list"
     :handler (fn [args _run-state]
                (handle-command api args))})
  (api.register :panel (panel-spec))
  (api.register :status
    {:name :todo
     :side :left
     :order 35
     :render status-render})
  (api.register :introspect
    {:name :state
     :description "Current todo list counts and panel state"
     :snapshot snapshot})
  (api.on :agent-started
    (fn [ev]
      (rebuild-from-messages! (?. ev :agent :messages))))
  (api.on :tool-result
    (fn [ev]
      (when (= (tostring ev.name) "todo_write")
        (adopt-details! (?. ev :result :details)))))
  (api.on :reset-conversation
    (fn [_]
      (clear!)
      (set state.visible? false)))
  (api.on :dismiss
    (fn [ev]
      (when state.visible?
        (set state.visible? false)
        (invalidate-cache!)
        (when ev.announce?
          (api.emit {:type :info :text "todos panel: off"})))))
  true)

(set M.register register!)
(set M.register! register!)
(set M.execute execute)
(set M.validate-items validate-items)
(set M.copy-items copy-items)
(set M.counts counts)
(set M.summary-line summary-line)
(set M.render-text render-text)
(set M.panel-spec panel-spec)
(set M.rebuild-from-messages! rebuild-from-messages!)
(set M._state state)
(set M._test {:adopt-details! adopt-details!
              :set-items! set-items!
              :clear! clear!})

M
