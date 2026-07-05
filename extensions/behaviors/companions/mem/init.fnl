;; Runtime memory diagnostics extension.
;;
;; Surface: a togglable :panel above the input that shows lua heap,
;; process memory, registry sizes, agent/session info, and a history
;; sparkline. /mem toggles visibility; /mem gc forces a GC pass.

(local state (require :fen.extensions.mem.state))
(local first-arg (. (require :fen.util.args) :first-arg))

(local OWNER :mem)
(local M {})

(fn round1 [n]
  (/ (math.floor (+ (* (or n 0) 10) 0.5)) 10))

(fn fmt-kb [n]
  (.. (tostring (round1 n)) " KB"))

(fn proc-status []
  "Return Linux process memory fields from /proc/self/status when available."
  (let [(f _err) (io.open "/proc/self/status" :r)
        out {}]
    (when f
      (each [line (f:lines)]
        (let [(k v) (string.match line "^(Vm%w+):%s+(%d+)%s+kB")]
          (when k
            (tset out k (tonumber v)))))
      (f:close))
    out))

(fn count-list [xs]
  (length (or xs [])))

(fn count-event-handlers [handlers]
  (var buckets 0)
  (var handlers-count 0)
  (each [_ entries (pairs (or handlers {}))]
    (set buckets (+ buckets 1))
    (set handlers-count (+ handlers-count (count-list entries))))
  (values buckets handlers-count))

(fn push-sample! [kb]
  (table.insert state.samples kb)
  (while (> (length state.samples) state.max-samples)
    (table.remove state.samples 1))
  (when (> kb (or state.peak-kb 0))
    (set state.peak-kb kb)))

(fn bar [value max-value width]
  (let [max-value (if (> (or max-value 0) 0) max-value 1)
        filled (math.floor (+ (* (/ value max-value) width) 0.5))
        parts []]
    (for [i 1 width]
      (table.insert parts (if (<= i filled) "#" ".")))
    (table.concat parts "")))

(fn dim [text]
  {:text text :style :dim})

(fn heading [text]
  {:text text :style :assistant})

(fn memory-rows [gc?]
  (let [before (collectgarbage :count)
        _ (when gc? (collectgarbage :collect))
        after (collectgarbage :count)
        collected (- before after)
        proc (proc-status)
        rows [(heading "Memory")]]
    (if gc?
        (do
          (table.insert rows (dim (.. "  lua heap before GC: " (fmt-kb before))))
          (table.insert rows (dim (.. "  lua heap after GC:  " (fmt-kb after))))
          (table.insert rows (dim (.. "  collected:          " (fmt-kb collected)))))
        (table.insert rows (dim (.. "  lua heap:           " (fmt-kb after)))))
    (when (> after (or state.peak-kb 0))
      (set state.peak-kb after))
    (table.insert rows (dim (.. "  peak observed heap: " (fmt-kb (or state.peak-kb 0)))))
    (when proc.VmRSS
      (table.insert rows (dim (.. "  process RSS:        " (fmt-kb proc.VmRSS)))))
    (when proc.VmHWM
      (table.insert rows (dim (.. "  process peak RSS:   " (fmt-kb proc.VmHWM)))))
    (when proc.VmSize
      (table.insert rows (dim (.. "  process vm size:    " (fmt-kb proc.VmSize)))))
    rows))

(fn app-rows [api run-state]
  (let [agent (?. run-state :agent)
        session (or (and api (api.session.info)) (?. run-state :session))
        rows [(heading "App")]]
    (table.insert rows (dim (.. "  messages: " (count-list (?. agent :messages)))))
    (when session
      (when session.id
        (table.insert rows (dim (.. "  session id: " (tostring session.id)))))
      (when session.path
        (table.insert rows (dim (.. "  session path: " (tostring session.path))))))
    rows))

(fn registry-rows [api]
  (let [tools (api.list :tools)
        commands (api.list :commands)
        fragments (api.list :prompt-fragments)
        exts (api.list :extensions)
        handlers (api.list :event-handlers)
        (event-buckets event-handlers) (count-event-handlers handlers)]
    [(heading "Registries")
     (dim (.. "  extensions: " (count-list exts)))
     (dim (.. "  tools: " (count-list tools)))
     (dim (.. "  commands: " (count-list commands)))
     (dim (.. "  prompt fragments: " (count-list fragments)))
     (dim (.. "  event handlers: " event-handlers " in " event-buckets " buckets"))]))

(fn history-rows []
  (let [rows []]
    (when (> (length state.samples) 1)
      (table.insert rows (heading "History"))
      (each [i kb (ipairs state.samples)]
        (table.insert rows
          (dim (.. "  " (string.format "%02d" i)
                   " [" (bar kb state.peak-kb 20) "] "
                   (fmt-kb kb))))))
    rows))

(fn append-rows! [out rows]
  (each [_ r (ipairs rows)]
    (table.insert out r)))

;; @doc fen.extensions.mem.report-rows
;; kind: function
;; signature: (report-rows run-state opts?) -> [PresenterRow]
;; summary: Build memory diagnostics rows for the /mem panel, including optional GC before/after output, app state, registries, and history.
;; tags: mem panel diagnostics rows
(fn M.report-rows [run-state opts ?api]
  "Build the memory report as a list of `{:text :style}` rows. Used by
   the /mem panel render and the text shim for tests. opts.gc? toggles
   the explicit before/after-GC memory rows."
  (let [opts (or opts {})
        api (or ?api state.api)
        rows []]
    (append-rows! rows (memory-rows opts.gc?))
    (when run-state
      (table.insert rows (dim ""))
      (append-rows! rows (app-rows api run-state)))
    (table.insert rows (dim ""))
    (append-rows! rows (registry-rows api))
    (let [hist (history-rows)]
      (when (> (length hist) 0)
        (table.insert rows (dim ""))
        (append-rows! rows hist)))
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
  (let [out [{:text (box-top w "mem") :style :dim}]]
    (each [_ row (ipairs content)]
      (table.insert out {:text (box-side w row.text) :style row.style}))
    (table.insert out {:text (box-bottom w) :style :dim})
    out))

(fn panel-rows [w]
  ;; Throttle to 1 Hz. The TUI repaints at ~33 Hz; rebuilding every
  ;; frame makes the heap value jitter too fast to read. The cache is
  ;; also invalidated when the terminal width changes so resize doesn't
  ;; leave a misaligned box on screen.
  (let [now (os.time)]
    (when (or (not state.cached-rows)
              (not= now state.cached-at)
              (not= w state.cached-w))
      (let [content (M.report-rows state.run-state {:gc? false} state.api)]
        (set state.cached-rows (bordered-rows w content)))
      (set state.cached-at now)
      (set state.cached-w w))
    state.cached-rows))

(fn invalidate-cache! []
  (set state.cached-rows nil)
  (set state.cached-at 0)
  (set state.cached-w 0))

;; @doc fen.extensions.mem.panel-spec
;; kind: function
;; signature: (panel-spec) -> PanelSpec
;; summary: Return the /mem panel contribution that sizes and renders the cached memory diagnostics above the input.
;; tags: mem panel register
(fn M.panel-spec []
  {:name :mem
   :placement :above-input
   :order 50
   :height (fn [ctx]
             (if state.visible?
                 (length (panel-rows (or (?. ctx :w) 80)))
                 0))
   :render (fn [ctx]
             (if state.visible?
                 (panel-rows (or (?. ctx :w) 80))
                 []))})

(fn handle-gc [api]
  (let [before (collectgarbage :count)]
    (collectgarbage :collect)
    (let [after (collectgarbage :count)
          collected (- before after)]
      (push-sample! after)
      (invalidate-cache!)
      (api.emit
        {:type :info
         :text (.. "mem gc: " (fmt-kb before) " → " (fmt-kb after)
                   " (collected " (fmt-kb collected) ")")}))))

(fn handle-toggle [api arg]
  (let [new-val (if (= arg :on) true
                    (= arg :off) false
                    (not state.visible?))]
    (when (and new-val (not state.visible?))
      ;; Panels are mutually exclusive — close any other open panel before
      ;; making mem visible. Each panel's :dismiss handler closes silently.
      (api.emit {:type :dismiss}))
    (set state.visible? new-val)
    (invalidate-cache!)
    (api.emit
      {:type :info
       :text (if new-val
                 "mem panel: on (/mem off or /mem to hide)"
                 "mem panel: off")})))

(fn register! [api]
  (set state.api api)
  (api.register :command
      {:name :mem
       :order 80
       :description "Toggle the memory diagnostics panel; /mem gc forces a GC pass"
       :handler (fn [args run-state]
                  (when run-state (set state.run-state run-state))
                  (let [arg (first-arg args)
                        kw (and arg (string.lower arg))]
                    (if (= kw "gc")
                        (handle-gc api)
                        (handle-toggle api kw))))})
    ;; @doc register-site:panel:mem
    ;; summary: Memory diagnostics panel backing the /mem command and heap history display.
    ;; tags: panel memory commands
    (api.register :panel (M.panel-spec))

    (api.register :introspect
      {:name :diagnostics
       :description "Current memory diagnostics panel, heap, and sample history summary"
       :snapshot (fn [_]
                   {:visible? state.visible?
                    :cached-w state.cached-w
                    :cached-at state.cached-at
                    :heap-kb (round1 (collectgarbage :count))
                    :peak-kb (round1 state.peak-kb)
                    :sample-count (length state.samples)
                    :max-samples state.max-samples
                    :has-run-state? (not= state.run-state nil)})})

    ;; Sample heap size on every llm turn end so the history bars in
    ;; the panel reflect actual usage, decoupled from the per-frame
    ;; render path.
    (api.on :llm-end
      (fn [_ev]
        (push-sample! (collectgarbage :count))))
    ;; Close on :dismiss (Esc, or another panel taking over). Silent
    ;; close keeps the transcript quiet when switching between panels.
    (api.on :dismiss
      (fn [ev]
        (when state.visible?
          (set state.visible? false)
          (invalidate-cache!)
          (when ev.announce?
            (api.emit {:type :info :text "mem panel: off"})))))
  true)

;; @doc fen.extensions.mem.register!
;; kind: data
;; signature: function
;; summary: Registration entrypoint alias for installing the /mem command, panel, sampling hook, and dismiss handler.
;; tags: mem register command panel
(set M.register register!)
(set M.register! register!)

;; @doc fen.extensions.mem._state
;; kind: data
;; signature: table
;; summary: Test and diagnostics alias for the persistent memory diagnostics state table.
;; tags: mem state tests
(set M._state state)

M
