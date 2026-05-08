;; /prompt: togglable panel listing system-prompt fragments.
;; /prompt rendered: emit the rendered prompt as a transcript blob.

(local panel-state (require :fen.extensions.prompt.state.prompt))

(local M {})

(fn trim [s]
  (-> (or s "") (string.gsub "^%s+" "") (string.gsub "%s+$" "")))

(fn rendered-arg? [args]
  (= (string.lower (trim args)) "rendered"))

(fn dim [text] {:text text :style :dim})
(fn heading [text] {:text text :style :assistant})

(fn fragment-rows [api]
  (let [items (api.list :prompt-fragments)
        rows [(heading "Prompt fragments")]]
    (if (= (length items) 0)
        (table.insert rows (dim "  (none)"))
        (each [_ f (ipairs items)]
          (let [name (if f.id
                         (.. (tostring f.owner) "/" (tostring f.id))
                         (tostring f.owner))]
            (table.insert rows
                          (dim (.. "  " (tostring f.order)
                                   "  " name
                                   "  seq=" (tostring f.seq)
                                   "  " (if f.dynamic? "dynamic" "static"))))
            (when f.title
              (table.insert rows (dim (.. "      title: " (tostring f.title)))))
            (when f.description
              (table.insert rows (dim (.. "      desc: " (tostring f.description))))))))
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
  (let [out [{:text (box-top w "prompt") :style :dim}]]
    (each [_ row (ipairs content)]
      (table.insert out {:text (box-side w row.text) :style row.style}))
    (table.insert out {:text (box-bottom w) :style :dim})
    out))

(fn panel-rows [api w]
  (let [now (os.time)]
    (when (or (not panel-state.cached-rows)
              (not= now panel-state.cached-at)
              (not= w panel-state.cached-w))
      (set panel-state.cached-rows (bordered-rows w (fragment-rows api)))
      (set panel-state.cached-at now)
      (set panel-state.cached-w w))
    panel-state.cached-rows))

(fn invalidate-cache! []
  (set panel-state.cached-rows nil)
  (set panel-state.cached-at 0)
  (set panel-state.cached-w 0))

(fn panel-spec [api]
  {:name :prompt
   :placement :above-input
   :order 50
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
          (api.emit {:type :info :text "prompt panel: off"}))
      (do
        (api.emit {:type :dismiss})
        (set panel-state.visible? true)
        (invalidate-cache!)
        (api.emit {:type :info :text "prompt panel: on"}))))

;; @doc fen.extensions.prompt.commands.prompt.register
;; kind: function
;; signature: (register api) -> nil
;; summary: Register the /prompt command and prompt-fragment panel for inspecting rendered system prompt state.
;; tags: commands prompt register
(fn M.register [api]
  (api.register :command
    {:name :prompt
     :order 30
     :description "Toggle the prompt-fragments panel; /prompt rendered emits the rendered prompt"
     :handler (fn [args state]
                (if (rendered-arg? args)
                    (api.emit
                      {:type :assistant-text
                       :text (or (?. state :agent :system-prompt) "")})
                    (handle-toggle api)))})
  ;; @doc register-site:panel:prompt
  ;; summary: Prompt-fragment inspection panel backing the /prompt command.
  ;; tags: panel prompt commands
  (api.register :panel (panel-spec api))

  (api.register :introspect
    {:name :panel
     :description "Current prompt-fragment panel state and fragment counts"
     :snapshot (fn [_]
                 (let [fragments (api.list :prompt-fragments)]
                   {:visible? panel-state.visible?
                    :cached-w panel-state.cached-w
                    :cached-at panel-state.cached-at
                    :fragment-count (length fragments)
                    :dynamic-count (accumulate [n 0 _ f (ipairs fragments)]
                                     (if f.dynamic? (+ n 1) n))}))})

  (api.on :dismiss
    (fn [ev]
      (when panel-state.visible?
        (set panel-state.visible? false)
        (invalidate-cache!)
        (when ev.announce?
          (api.emit {:type :info :text "prompt panel: off"}))))))

M
