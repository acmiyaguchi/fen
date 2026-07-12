;; /prompt: togglable panel listing system-prompt fragments.
;; /prompt rendered: emit the rendered prompt as a transcript blob.

(local panel (require :fen.util.panel))
(local panel-state (require :fen.extensions.prompt.state.prompt))
(local system-prompt (require :fen.core.prompt))
(local tokens (require :fen.util.tokens))

(local M {})

(local trim (. (require :fen.util.text) :trim))

(fn arg-word [args]
  (string.lower (trim (or args ""))))

(fn rendered-arg? [args]
  (= (arg-word args) "rendered"))

(fn stats-arg? [args]
  (= (arg-word args) "stats"))

(local dim panel.dim)
(local heading panel.heading)

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

(fn panel-rows [api w]
  (panel.throttled-rows panel-state w "prompt" #(fragment-rows api)))

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
  (panel.toggle! panel-state api.emit "prompt"))

(fn frag-name [s]
  (if s.id
      (.. (tostring s.owner) "/" (tostring s.id))
      (tostring s.owner)))

(fn stats-text [state]
  "Render a per-fragment size report for the current runtime context. Sizes are
   recomputed from the live fragment renderers using the session opts/tools, so
   volatile fragments (date, cwd) reflect now rather than the string baked into
   agent.system-prompt at construction; totals track the real prompt closely."
  (let [opts (?. state :opts)
        tools (or (?. state :agent :tools) [])
        rows (system-prompt.stats opts tools)
        lines ["prompt stats (bytes / ~tokens per fragment)"]]
    (if (= (length rows) 0)
        (table.insert lines "  (no fragments registered)")
        (each [_ s (ipairs rows)]
          (table.insert lines
            (string.format "  %-4s %-32s %8d B  ~%s"
                           (tostring s.order)
                           (frag-name s)
                           s.bytes
                           (tokens.fmt-tokens s.approx-tokens)))))
    (table.insert lines
      (string.format "  %-4s %-32s %8d B  ~%s"
                     "" "TOTAL" (or (. rows :total-bytes) 0)
                     (tokens.fmt-tokens (or (. rows :total-approx-tokens) 0))))
    (table.concat lines "\n")))

;; @doc fen.extensions.prompt.commands.prompt.register
;; kind: function
;; signature: (register api) -> nil
;; summary: Register the /prompt command and prompt-fragment panel for inspecting rendered system prompt state.
;; tags: commands prompt register
(fn M.register [api]
  (api.register :command
    {:name :prompt
     :order 30
     :description "Toggle the prompt-fragments panel; /prompt rendered emits the rendered prompt; /prompt stats reports per-fragment sizes"
     :handler (fn [args state]
                (if (rendered-arg? args)
                    (api.emit
                      {:type :assistant-text
                       :text (or (?. state :agent :system-prompt) "")})
                    (stats-arg? args)
                    (api.emit
                      {:type :assistant-text
                       :text (stats-text state)})
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
    (fn [ev] (panel.dismissed! panel-state api.emit "prompt" ev))))

M
