;; Extension-management slash commands.
;;
;; Bare /extensions opens a selector over loaded/discovered extensions, then
;; shows the selected extension in a persistent panel. /extensions <name>
;; jumps directly to that detail panel.
;; /reload-extension keeps its existing transcript-emit behavior since
;; it's an action with audit-trail value.

(local util (require :fen.extensions.extensions_inspector.util))
(local panel-state (require :fen.extensions.extensions_inspector.state.extensions))

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

(fn extension-items [api]
  (let [items []]
    (each [_ e (ipairs (api.list :extensions))]
      (table.insert items e))
    (table.sort items (fn [a b] (< (tostring a.name) (tostring b.name))))
    items))

(fn find-extension [api name]
  (var found nil)
  (each [_ e (ipairs (api.list :extensions))]
    (when (and (not found) (= (tostring e.name) (tostring name)))
      (set found e)))
  found)

(fn render-value [v]
  (let [(ok? fennel) (pcall require :fennel)]
    (if (and ok? fennel.view)
        (fennel.view v {:one-line? false :max-sparse-gap 3})
        (util.safe-json v))))

(fn add-snapshot-lines! [lines api e]
  (let [owner-name (tostring e.name)
        snapshots (api.introspect.collect owner-name)
        by-owner (or (. snapshots e.name) (. snapshots owner-name))]
    (when (and by-owner (> (length (render-value by-owner)) 0))
      (var any? false)
      (each [_ _ (pairs by-owner)] (set any? true))
      (when any?
        (table.insert lines (heading "snapshots:"))
        (each [name value (pairs by-owner)]
          (table.insert lines (dim (.. "  " (tostring name) ":")))
          (each [line (string.gmatch (render-value value) "[^\n]+")]
            (table.insert lines (dim (.. "    " line)))))))))

(local REGISTRY-KINDS
  [{:kind :commands :label "commands"}
   {:kind :tools :label "tools"}
   {:kind :controls :label "controls"}
   {:kind :status :label "status"}
   {:kind :panels :label "panels"}
   {:kind :presenters :label "presenters"}
   {:kind :providers :label "providers"}
   {:kind :auth-backends :label "auth backends"}
   {:kind :session-backends :label "session backends"}
   {:kind :prompt-fragments :label "prompt fragments"}
   {:kind :event-handlers :label "events"}
   {:kind :hooks :label "hooks"}
   {:kind :introspectors :label "introspectors"}])

(fn normalize-kind [s]
  (let [s (tostring (or s ""))]
    (if (= s "command") :commands
        (= s "commands") :commands
        (= s "tool") :tools
        (= s "tools") :tools
        (= s "control") :controls
        (= s "controls") :controls
        (= s "status") :status
        (= s "panel") :panels
        (= s "panels") :panels
        (= s "presenter") :presenters
        (= s "presenters") :presenters
        (= s "provider") :providers
        (= s "providers") :providers
        (= s "auth-backend") :auth-backends
        (= s "auth-backends") :auth-backends
        (= s "session-backend") :session-backends
        (= s "session-backends") :session-backends
        (= s "prompt") :prompt-fragments
        (= s "prompt-fragment") :prompt-fragments
        (= s "prompt-fragments") :prompt-fragments
        (= s "event") :event-handlers
        (= s "events") :event-handlers
        (= s "event-handler") :event-handlers
        (= s "event-handlers") :event-handlers
        (= s "hook") :hooks
        (= s "hooks") :hooks
        (= s "introspector") :introspectors
        (= s "introspectors") :introspectors
        nil)))

(fn kind-label [kind]
  (var label (tostring kind))
  (each [_ spec (ipairs REGISTRY-KINDS)]
    (when (= spec.kind kind)
      (set label spec.label)))
  label)

(fn safe-list [api kind]
  (let [(ok? data) (pcall api.list kind)]
    (if ok? data [])))

(fn display-name [kind rec]
  (let [raw (or rec.name rec.id rec.event rec.title kind)]
    (if (= kind :commands)
        (let [s (tostring raw)]
          (if (= (string.sub s 1 1) "/") s (.. "/" s)))
        (= kind :event-handlers)
        (.. (tostring raw) " event")
        (= kind :hooks)
        (tostring (or rec.event :before-tool))
        (tostring raw))))

(fn record-detail [kind rec]
  (let [parts []]
    (when rec.placement (table.insert parts (.. "placement: " (tostring rec.placement))))
    (when rec.side (table.insert parts (.. "side: " (tostring rec.side))))
    (when rec.api (table.insert parts (.. "api: " (tostring rec.api))))
    (when rec.order (table.insert parts (.. "order: " (tostring rec.order))))
    (when (and (= kind :prompt-fragments) rec.dynamic?)
      (table.insert parts "dynamic"))
    (if (> (length parts) 0)
        (.. " (" (table.concat parts ", ") ")")
        "")))

(fn registry-records [api kind]
  (let [out []]
    (if (= kind :event-handlers)
        (each [event-name entries (pairs (safe-list api kind))]
          (each [_ rec (ipairs entries)]
            (table.insert out {:event event-name :owner rec.owner})))
        (each [_ rec (ipairs (safe-list api kind))]
          (table.insert out rec)))
    (table.sort out
                (fn [a b]
                  (let [an (display-name kind a)
                        bn (display-name kind b)]
                    (if (= an bn)
                        (< (tostring (or a.owner ""))
                           (tostring (or b.owner "")))
                        (< an bn)))))
    out))

(fn contributions-for-owner [api owner]
  (let [owner (tostring owner)
        out []]
    (each [_ spec (ipairs REGISTRY-KINDS)]
      (let [items []]
        (each [_ rec (ipairs (registry-records api spec.kind))]
          (when (= (tostring (or rec.owner "")) owner)
            (table.insert items rec)))
        (when (> (length items) 0)
          (table.insert out {:kind spec.kind :label spec.label :items items}))))
    out))

(fn add-contribution-lines! [lines api e]
  (let [groups (contributions-for-owner api e.name)]
    (table.insert lines (heading "registered:"))
    (if (= (length groups) 0)
        (table.insert lines (dim "  (none)"))
        (each [_ group (ipairs groups)]
          (let [names []]
            (each [_ rec (ipairs group.items)]
              (table.insert names (.. (display-name group.kind rec)
                                      (record-detail group.kind rec))))
            (table.insert lines
                          (dim (.. "  " group.label ": "
                                   (table.concat names ", ")))))))))

(fn registry-lines [api ?kind]
  (let [kind (and ?kind (normalize-kind ?kind))
        specs []
        rows [(heading (if kind
                           (.. "Registry: " (kind-label kind))
                           "Registry"))]]
    (if kind
        (table.insert specs {:kind kind :label (kind-label kind)})
        (each [_ spec (ipairs REGISTRY-KINDS)]
          (table.insert specs spec)))
    (each [_ spec (ipairs specs)]
      (let [records (registry-records api spec.kind)]
        (table.insert rows (heading spec.label))
        (if (= (length records) 0)
            (table.insert rows (dim "  (none)"))
            (each [_ rec (ipairs records)]
              (table.insert rows
                            (dim (.. "  " (pad (display-name spec.kind rec) 24)
                                     " owner: " (tostring (or rec.owner "unknown"))
                                     (record-detail spec.kind rec))))))))
    rows))

(fn extension-detail-lines [api e]
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
    (add-contribution-lines! lines api e)
    (add-snapshot-lines! lines api e)
    lines))

(fn extension-choices [api]
  (let [choices []]
    (each [_ e (ipairs (extension-items api))]
      (table.insert choices
                    {:label (.. (tostring e.name)
                                "  " (tostring e.status)
                                "  " (origin-label e))
                     :value e
                     :description (or e.description e.path "")}))
    choices))

(fn extension-rows [api]
  (let [items (extension-items api)
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

(fn selected-extension-rows [api]
  (if (= panel-state.view :registry)
      (registry-lines api panel-state.registry-kind)
      (let [e (and panel-state.selected-name
                   (find-extension api panel-state.selected-name))]
        (if e
            (extension-detail-lines api e)
            (extension-rows api)))))

(fn panel-title []
  (if (= panel-state.view :registry)
      (if panel-state.registry-kind
          (.. "registry: " (kind-label panel-state.registry-kind))
          "registry")
      panel-state.selected-name
      (.. "extension: " (tostring panel-state.selected-name))
      "extensions"))

(fn panel-rows [api w]
  (let [now (os.time)]
    (when (or (not panel-state.cached-rows)
              (not= now panel-state.cached-at)
              (not= w panel-state.cached-w)
              (not= panel-state.selected-name panel-state.cached-selected-name)
              (not= panel-state.view panel-state.cached-view)
              (not= panel-state.registry-kind panel-state.cached-registry-kind))
      (set panel-state.cached-rows
           (bordered-rows w (selected-extension-rows api) (panel-title)))
      (set panel-state.cached-at now)
      (set panel-state.cached-w w)
      (set panel-state.cached-selected-name panel-state.selected-name)
      (set panel-state.cached-view panel-state.view)
      (set panel-state.cached-registry-kind panel-state.registry-kind))
    panel-state.cached-rows))

(fn invalidate-cache! []
  (set panel-state.cached-rows nil)
  (set panel-state.cached-at 0)
  (set panel-state.cached-w 0)
  (set panel-state.cached-selected-name nil)
  (set panel-state.cached-view nil)
  (set panel-state.cached-registry-kind nil))

(fn show-registry-panel [api ?kind]
  (let [kind (and ?kind (normalize-kind ?kind))]
    (if (and ?kind (not kind))
        (api.emit {:type :error
                   :error (.. "unknown registry kind: " (tostring ?kind))})
        (do
          (api.emit {:type :dismiss})
          (set panel-state.view :registry)
          (set panel-state.registry-kind kind)
          (set panel-state.selected-name nil)
          (set panel-state.visible? true)
          (invalidate-cache!)
          (api.emit {:type :redraw})))))

(fn show-extension-panel [api name]
  (let [e (find-extension api name)]
    (if e
        (do
          (api.emit {:type :dismiss})
          (set panel-state.view :detail)
          (set panel-state.registry-kind nil)
          (set panel-state.selected-name (tostring e.name))
          (set panel-state.visible? true)
          (invalidate-cache!)
          (api.emit {:type :redraw}))
        (api.emit {:type :error
                          :error (.. "extension not found: " (tostring name))}))))

(fn panel-spec [api]
  {:name :extensions
   :placement :above-input
   :order 60
   :height (fn [ctx]
             (if panel-state.visible?
                 (length (panel-rows api (or (?. ctx :w) 80)))
                 0))
   :render (fn [ctx]
             (if panel-state.visible?
                 (panel-rows api (or (?. ctx :w) 80))
                 []))})

(fn handle-toggle [api]
  (if panel-state.visible?
      (do (set panel-state.visible? false)
          (invalidate-cache!)
          (api.emit {:type :info :text "extensions panel: off"}))
      (do
        (api.emit {:type :dismiss})
        (set panel-state.view :extensions)
        (set panel-state.registry-kind nil)
        (set panel-state.selected-name nil)
        (set panel-state.visible? true)
        (invalidate-cache!)
        (api.emit {:type :info :text "extensions panel: on"}))))

(fn pick-extension! [api]
  (let [choices (extension-choices api)]
    (if (= (length choices) 0)
        (api.emit {:type :info :text "no extensions loaded"})
        (let [picked (api.ui.select {:label "extension details"
                                 :choices choices})]
          (when picked
            (let [e (or picked.value picked)]
              (when e.name
                (show-extension-panel api e.name))))))))

(fn split-args [args]
  (let [out []]
    (if (= (type args) :table)
        (each [_ arg (ipairs args)]
          (table.insert out (tostring arg)))
        (each [arg (string.gmatch (tostring (or args "")) "%S+")]
          (table.insert out arg)))
    out))

;; @doc fen.extensions.extensions_inspector.commands.extension.register
;; kind: function
;; signature: (register api) -> nil
;; summary: Register extension management commands plus the extension picker/detail panel and dismiss handler.
;; tags: commands extensions register
(fn M.register [api]
  (api.register :command
    {:name :reload-extension
     :order 20
     :description "Reload one external extension by name"
     :idle-only? true
     :handler (fn [args state]
                (let [name (util.first-arg args)]
                  (if (or (not name) (= name ""))
                      (api.emit {:type :error
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
                                (api.emit {:type :info
                                                  :text (.. "reloaded extension: " name)})))
                            (api.emit {:type :error
                                              :error (.. "reload-extension: "
                                                         (tostring err))}))))))})

  (api.register :command
    {:name :extensions
     :order 10
     :description "Pick an extension, show details, or inspect live registry"
     :handler (fn [args _state]
                (let [parts (split-args args)
                      name (. parts 1)]
                  (if (= name "registry")
                      (show-registry-panel api (. parts 2))
                      (and name (not= name ""))
                      (show-extension-panel api name)
                      (pick-extension! api))))})

  ;; @doc register-site:panel:extensions
  ;; summary: Extension detail and picker panel backing the /extensions command.
  ;; tags: panel extensions commands
  (api.register :panel (panel-spec api))

  (api.register :introspect
    {:name :panel
     :description "Current /extensions panel state and cache metadata"
     :snapshot (fn [_]
                 {:visible? panel-state.visible?
                  :view panel-state.view
                  :selected-name panel-state.selected-name
                  :registry-kind panel-state.registry-kind
                  :cached-w panel-state.cached-w
                  :cached-at panel-state.cached-at
                  :cached-selected-name panel-state.cached-selected-name})})

  (api.on :dismiss
    (fn [ev]
      (when panel-state.visible?
        (set panel-state.visible? false)
        (invalidate-cache!)
        (when ev.announce?
          (api.emit {:type :info :text "extensions panel: off"}))))))

(tset M :_extension-detail-lines extension-detail-lines)
(tset M :_registry-lines registry-lines)
(tset M :_contributions-for-owner contributions-for-owner)

M
