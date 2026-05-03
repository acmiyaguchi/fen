;; Extension-management slash commands.
;;
;; Bare /extensions opens a selector over loaded/discovered extensions, then
;; shows the selected extension in a persistent panel. /extensions <name>
;; jumps directly to that detail panel.
;; /reload-extension keeps its existing transcript-emit behavior since
;; it's an action with audit-trail value.

(local extensions (require :fen.core.extensions))
(local util (require :fen.extensions.builtin_commands.util))
(local panel-state (require :fen.extensions.builtin_commands.state.extensions))

(local M {})

(fn dim [text] {:text text :style :dim})
(fn heading [text] {:text text :style :assistant})

(fn origin-label [e]
  (if e.first-party? "built-in" "external"))

(fn fit [s w]
  (let [s (tostring (or s ""))]
    (if (> (length s) w)
        (if (> w 1) (.. (string.sub s 1 (- w 1)) "…") "…")
        s)))

(fn pad [s w]
  (let [s (fit s w)
        n (length s)]
    (.. s (string.rep " " (math.max 0 (- w n))))))

(fn table-row [name status origin versions path]
  (.. "  "
      (pad name 18) "  "
      (pad status 12) "  "
      (pad origin 10) "  "
      (pad versions 3) "  "
      (tostring (or path ""))))

(fn join-list [items]
  (if (or (not items) (= (length items) 0))
      "(none)"
      (let [parts []]
        (each [_ item (ipairs items)]
          (table.insert parts (tostring item)))
        (table.concat parts ", "))))

(fn extension-items []
  (let [items []]
    (each [_ e (ipairs (extensions.list :extensions))]
      (table.insert items e))
    (table.sort items (fn [a b] (< (tostring a.name) (tostring b.name))))
    items))

(fn find-extension [name]
  (var found nil)
  (each [_ e (ipairs (extensions.list :extensions))]
    (when (and (not found) (= (tostring e.name) (tostring name)))
      (set found e)))
  found)

(fn extension-detail-lines [e]
  (let [lines [(heading (.. "Extension: " (tostring e.name)))
               (dim (.. "status: " (tostring e.status)))
               (dim (.. "origin: " (origin-label e)))
               (dim (.. "source: " (tostring (or e.source "unknown"))))
               (dim (.. "discovered versions: " (tostring (or e.version-count 1))))]]
    (when e.description
      (table.insert lines (dim (.. "description: " (tostring e.description)))))
    (when e.path
      (table.insert lines (dim (.. "active path: " (tostring e.path)))))
    (when (and e.versions (> (length e.versions) 0))
      (table.insert lines (dim "found paths:"))
      (each [_ v (ipairs e.versions)]
        (table.insert lines
                      (dim (.. "  " (if v.active? "* " "  ")
                               (tostring (or v.source "unknown"))
                               "  " (tostring (or v.path "")))))))
    (when e.entry-module
      (table.insert lines (dim (.. "entry module: " (tostring e.entry-module)))))
    (when e.entry
      (table.insert lines (dim (.. "entry file: " (tostring e.entry)))))
    (when e.presenter
      (table.insert lines (dim (.. "presenter: " (tostring e.presenter)))))
    (when e.interactive-only?
      (table.insert lines (dim "interactive only: true")))
    (table.insert lines (dim (.. "reload modules: " (join-list e.reload-modules))))
    (when (and e.reload-exclude (> (length e.reload-exclude) 0))
      (table.insert lines (dim (.. "reload excludes: " (join-list e.reload-exclude)))))
    (when e.missing
      (table.insert lines (dim (.. "missing deps: " (join-list e.missing)))))
    (when e.error
      (table.insert lines (dim (.. "error: " (tostring e.error)))))
    lines))

(fn extension-choices []
  (let [choices []]
    (each [_ e (ipairs (extension-items))]
      (table.insert choices
                    {:label (.. (tostring e.name)
                                "  " (tostring e.status)
                                "  " (origin-label e))
                     :value e
                     :description (or e.description e.path "")}))
    choices))

(fn extension-rows []
  (let [items (extension-items)
        rows [(heading "Extensions")]]
    (if (= (length items) 0)
        (table.insert rows (dim "  (none loaded)"))
        (do
          (table.insert rows (dim (table-row "name" "status" "origin" "#" "path")))
          ;; Keep this ASCII: byte-oriented terminal clipping can split
          ;; multi-byte box/separator glyphs inside a table cell.
          (table.insert rows (dim (table-row "----" "------" "------" "-" "----")))
          (each [_ e (ipairs items)]
            (table.insert rows
                          (dim (table-row e.name
                                          e.status
                                          (origin-label e)
                                          (or e.version-count 1)
                                          e.path))))))
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
        n (length text)
        clipped (if (> n inner-w) (string.sub text 1 inner-w) text)
        pad (math.max 0 (- inner-w (length clipped)))]
    (.. "│ " clipped (string.rep " " pad) " │")))

(fn wrap-text [text width]
  (let [out []
        text (tostring (or text ""))
        width (math.max 1 width)]
    (var rest text)
    (while (> (length rest) width)
      (var cut width)
      (for [i width 1 -1]
        (when (and (= cut width) (= (string.sub rest i i) " "))
          (set cut i)))
      (if (<= cut 1)
          (do
            (table.insert out (string.sub rest 1 width))
            (set rest (string.sub rest (+ width 1))))
          (do
            (table.insert out (string.sub rest 1 (- cut 1)))
            (set rest (string.sub rest (+ cut 1))))))
    (table.insert out rest)
    out))

(fn bordered-rows [w content ?title]
  (let [out [{:text (box-top w (or ?title "extensions")) :style :dim}]
        inner-w (math.max 1 (- w 4))]
    (each [_ row (ipairs content)]
      (each [_ line (ipairs (wrap-text row.text inner-w))]
        (table.insert out {:text (box-side w line) :style row.style})))
    (table.insert out {:text (box-bottom w) :style :dim})
    out))

(fn selected-extension-rows []
  (let [e (and panel-state.selected-name
               (find-extension panel-state.selected-name))]
    (if e
        (extension-detail-lines e)
        (extension-rows))))

(fn panel-title []
  (if panel-state.selected-name
      (.. "extension: " (tostring panel-state.selected-name))
      "extensions"))

(fn panel-rows [w]
  (let [now (os.time)]
    (when (or (not panel-state.cached-rows)
              (not= now panel-state.cached-at)
              (not= w panel-state.cached-w)
              (not= panel-state.selected-name panel-state.cached-selected-name))
      (set panel-state.cached-rows
           (bordered-rows w (selected-extension-rows) (panel-title)))
      (set panel-state.cached-at now)
      (set panel-state.cached-w w)
      (set panel-state.cached-selected-name panel-state.selected-name))
    panel-state.cached-rows))

(fn invalidate-cache! []
  (set panel-state.cached-rows nil)
  (set panel-state.cached-at 0)
  (set panel-state.cached-w 0)
  (set panel-state.cached-selected-name nil))

(fn show-extension-panel [name]
  (let [e (find-extension name)]
    (if e
        (do
          (extensions.emit {:type :dismiss})
          (set panel-state.selected-name (tostring e.name))
          (set panel-state.visible? true)
          (invalidate-cache!)
          (extensions.emit {:type :redraw}))
        (extensions.emit {:type :error
                          :error (.. "extension not found: " (tostring name))}))))

(fn panel-spec []
  {:name :extensions
   :placement :above-input
   :order 60
   :height (fn [ctx]
             (if panel-state.visible?
                 (length (panel-rows (or (?. ctx :w) 80)))
                 0))
   :render (fn [ctx]
             (if panel-state.visible?
                 (panel-rows (or (?. ctx :w) 80))
                 []))})

(fn handle-toggle []
  (if panel-state.visible?
      (do (set panel-state.visible? false)
          (invalidate-cache!)
          (extensions.emit {:type :info :text "extensions panel: off"}))
      (do
        (extensions.emit {:type :dismiss})
        (set panel-state.selected-name nil)
        (set panel-state.visible? true)
        (invalidate-cache!)
        (extensions.emit {:type :info :text "extensions panel: on"}))))

(fn pick-extension! []
  (let [choices (extension-choices)]
    (if (= (length choices) 0)
        (extensions.emit {:type :info :text "no extensions loaded"})
        (let [ui (extensions.build-ui-slot)
              picked (ui.select {:label "extension details"
                                 :choices choices})]
          (when picked
            (let [e (or picked.value picked)]
              (when e.name
                (show-extension-panel e.name))))))))

(fn M.register [api]
  (api.register :command
    {:name :reload-extension
     :order 20
     :description "Reload one external extension by name"
     :idle-only? true
     :handler (fn [args state]
                (let [name (util.first-arg args)]
                  (if (or (not name) (= name ""))
                      (extensions.emit {:type :error
                                        :error "usage: /reload-extension <name>"})
                      (let [(ok? err) (if state.reload-extension
                                          (state.reload-extension name)
                                          (values false "extension loader unavailable"))]
                        (if ok?
                            (do
                              (when state.reload-model-providers
                                (state.reload-model-providers))
                              (let [saved state.agent.messages
                                    new-agent (state.make-agent-from-opts
                                                state.opts state.on-event
                                                state.agent-extra)]
                                (set new-agent.messages saved)
                                (set state.agent new-agent)
                                (invalidate-cache!)
                                (extensions.emit {:type :info
                                                  :text (.. "reloaded extension: " name)})))
                            (extensions.emit {:type :error
                                              :error (.. "reload-extension: "
                                                         (tostring err))}))))))})

  (api.register :command
    {:name :extensions
     :order 10
     :description "Pick an extension and show its detail panel"
     :handler (fn [args _state]
                (let [name (util.first-arg args)]
                  (if (and name (not= name ""))
                      (show-extension-panel name)
                      (pick-extension!))))})

  (api.register :panel (panel-spec))
  (api.on :dismiss
    (fn [ev]
      (when panel-state.visible?
        (set panel-state.visible? false)
        (invalidate-cache!)
        (when ev.announce?
          (extensions.emit {:type :info :text "extensions panel: off"}))))))

M
