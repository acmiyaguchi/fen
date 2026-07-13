;; Error introspection panel for the TUI.
;;
;; Keeps errors fixable in-place: `/errors` opens a compact panel with the
;; recent error summaries plus traceback/location detail when available.
;; State is stored on the persistent TUI state table so the toggle survives
;; `/reload`; behavior stays reloadable through the TUI manifest.

(local state (require :fen.extensions.tui.state))

(local M {})

(local MAX-ERRORS 5)
(local MAX-DETAIL-LINES 18)

;; @doc fen.extensions.tui.panels.errors.ensure-defaults!
;; kind: function
;; signature: (ensure-defaults!) -> nil
;; summary: Backfill persistent error-panel visibility state on live TUI state tables after reloads.
;; tags: tui panel errors state reload
(fn M.ensure-defaults! []
  (when (= state.error-panel-visible? nil)
    (set state.error-panel-visible? false)))

(fn line [text style]
  {:text (or text "") :style (or style :dim)})

(fn split-lines [s]
  (let [out []
        text (tostring (or s ""))]
    (var i 1)
    (let [n (length text)]
      (while (<= i n)
        (let [j (string.find text "\n" i true)]
          (if j
              (do (table.insert out (string.sub text i (- j 1)))
                  (set i (+ j 1)))
              (do (table.insert out (string.sub text i n))
                  (set i (+ n 1))))))
      (when (and (= n 0))
        (table.insert out "")))
    out))

(fn error-summary [ev]
  (if (= ev.type :extension-error)
      (.. "extension handler failed owner=" (tostring (or ev.owner "?"))
          " event=" (tostring (or ev.event "?"))
          ": " (tostring (or ev.error "")))
      (tostring (or ev.error ev.text ""))))

(fn error-detail [ev]
  (or ev.traceback ev.stack ev.detail ev.details))

(fn recent-errors []
  (let [out []]
    (var i (length (or state.transcript [])))
    (while (and (> i 0) (< (length out) MAX-ERRORS))
      (let [ev (. state.transcript i)]
        (when (or (= ev.type :error) (= ev.type :extension-error))
          (table.insert out ev)))
      (set i (- i 1)))
    out))

;; @doc fen.extensions.tui.panels.errors.toggle!
;; kind: function
;; signature: (toggle! value?) -> boolean
;; summary: Toggle or set the TUI error panel visibility and return the new visible state.
;; tags: tui panel errors visibility
(fn M.toggle! [?value]
  (M.ensure-defaults!)
  (set state.error-panel-visible?
       (if (= ?value nil) (not state.error-panel-visible?) ?value))
  state.error-panel-visible?)

;; @doc fen.extensions.tui.panels.errors.visible?
;; kind: function
;; signature: (visible?) -> boolean
;; summary: Report whether the recent-errors panel should currently reserve below-status space.
;; tags: tui panel errors visibility
(fn M.visible? []
  (M.ensure-defaults!)
  state.error-panel-visible?)

;; @doc fen.extensions.tui.panels.errors.has-errors?
;; kind: function
;; signature: (has-errors?) -> boolean
;; summary: Report whether the active transcript contains an error row.
;; tags: tui panel errors status
(fn M.has-errors? []
  ;; Usually finds a recent error immediately. Avoid materializing the panel's
  ;; bounded detail list on every status paint.
  (var found? false)
  (var i (length (or state.transcript [])))
  (while (and (> i 0) (not found?))
    (let [ev (. state.transcript i)]
      (when (or (= ev.type :error) (= ev.type :extension-error))
        (set found? true)))
    (set i (- i 1)))
  found?)

(fn panel-height [ctx]
  (M.ensure-defaults!)
  (if state.error-panel-visible?
      (math.min 14 (math.max 4 (math.floor (/ (or ctx.w 80) 7))))
      0))

(fn panel-render [_ctx]
  (M.ensure-defaults!)
  (let [rows [(line "Errors — /errors to close, /errors clear to remove error rows" :error)]
        errs (recent-errors)]
    (if (= (length errs) 0)
        (table.insert rows (line "  no errors in this transcript" :dim))
        (each [idx ev (ipairs errs)]
          (table.insert rows (line (.. "#" (tostring idx) " " (error-summary ev)) :error))
          (let [detail (error-detail ev)]
            (when detail
              (var n 0)
              (each [_ l (ipairs (split-lines detail))]
                (when (< n MAX-DETAIL-LINES)
                  (table.insert rows (line (.. "    " l) :dim))
                  (set n (+ n 1))))
              (when (>= n MAX-DETAIL-LINES)
                (table.insert rows (line "    …" :dim)))))))
    rows))

;; @doc fen.extensions.tui.panels.errors.clear-transcript-errors!
;; kind: function
;; signature: (clear-transcript-errors!) -> nil
;; summary: Remove error and extension-error events from the transcript and invalidate transcript layout cache.
;; tags: tui panel errors transcript cache
(fn M.clear-transcript-errors! []
  (let [kept []]
    (each [_ ev (ipairs (or state.transcript []))]
      (when (not (or (= ev.type :error) (= ev.type :extension-error)))
        (table.insert kept ev)))
    (set state.transcript kept)
    (set state.transcript-layout-cache nil)))

;; @doc fen.extensions.tui.panels.errors.spec
;; kind: function
;; signature: (spec) -> PanelSpec
;; summary: Return the error introspection panel contribution for below-status rendering.
;; tags: tui panel errors register
(fn M.spec []
  {:name :errors
   :placement :below-status
   :order 5
   :height panel-height
   :render panel-render})

M
