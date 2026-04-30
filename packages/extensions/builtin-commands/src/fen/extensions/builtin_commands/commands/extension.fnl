;; Extension-management slash commands.
;;
;; Bare /extensions toggles a panel listing loaded/discovered extensions.
;; /reload-extension keeps its existing transcript-emit behavior since
;; it's an action with audit-trail value.

(local extensions (require :fen.core.extensions))
(local util (require :fen.extensions.builtin_commands.util))
(local panel-state (require :fen.extensions.builtin_commands.state.extensions))

(local M {})

(fn dim [text] {:text text :style :dim})
(fn heading [text] {:text text :style :assistant})

(fn extension-rows []
  (let [items (extensions.list :extensions)
        rows [(heading "Extensions")]]
    (if (= (length items) 0)
        (table.insert rows (dim "  (none loaded)"))
        (each [_ e (ipairs items)]
          (table.insert rows
                        (dim (.. "  " (tostring e.name)
                                 " — " (tostring e.status)
                                 (if e.path (.. " — " e.path) ""))))))
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

(fn bordered-rows [w content]
  (let [out [{:text (box-top w "extensions") :style :dim}]]
    (each [_ row (ipairs content)]
      (table.insert out {:text (box-side w row.text) :style row.style}))
    (table.insert out {:text (box-bottom w) :style :dim})
    out))

(fn panel-rows [w]
  (let [now (os.time)]
    (when (or (not panel-state.cached-rows)
              (not= now panel-state.cached-at)
              (not= w panel-state.cached-w))
      (set panel-state.cached-rows (bordered-rows w (extension-rows)))
      (set panel-state.cached-at now)
      (set panel-state.cached-w w))
    panel-state.cached-rows))

(fn invalidate-cache! []
  (set panel-state.cached-rows nil)
  (set panel-state.cached-at 0)
  (set panel-state.cached-w 0))

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
        (set panel-state.visible? true)
        (invalidate-cache!)
        (extensions.emit {:type :info :text "extensions panel: on"}))))

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
                            (let [saved state.agent.messages
                                  new-agent (state.make-agent-from-opts
                                              state.opts state.on-event state.loader
                                              state.agent-extra)]
                              (set new-agent.messages saved)
                              (set state.agent new-agent)
                              (invalidate-cache!)
                              (extensions.emit {:type :info
                                                :text (.. "reloaded extension: " name)}))
                            (extensions.emit {:type :error
                                              :error (.. "reload-extension: "
                                                         (tostring err))}))))))})

  (api.register :command
    {:name :extensions
     :order 10
     :description "Toggle the extensions panel"
     :handler (fn [_args _state] (handle-toggle))})

  (api.register :panel (panel-spec))
  (api.on :dismiss
    (fn [_ev]
      (when panel-state.visible?
        (set panel-state.visible? false)
        (invalidate-cache!)))))

M
