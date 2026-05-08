;; TUI render code: layout, transcript composition, paint regions, redraw.
;;
;; paint.fnl orchestrates the redraw and owns the placement walker.
;; Low-level termbox primitives live in `draw.fnl`; per-region rendering
;; lives in `panels/{transcript,status,busy}.fnl` and `input.fnl`.
;; paint imports `core.extensions` to enumerate registered :panel items;
;; that is the contract — presentation reads UI contributions.
;; Redraw scheduling lives in `redraw.fnl`, a state-only leaf module used
;; by input, ingest, and paint without creating a paint/input cycle.
;;
;; Hot-reload note: in RELOADABLE; manual-reload! mutates module exports in
;; place so callers keep their module-table references and pick up new code
;; on the next call.

(local state (require :fen.extensions.tui.state))
(local tb (require :termbox2))
(local md (require :fen.extensions.tui.markdown))
(local draw (require :fen.extensions.tui.draw))
(local redraw (require :fen.extensions.tui.redraw))
(local transcript (require :fen.extensions.tui.panels.transcript))
(local status-panel (require :fen.extensions.tui.panels.status))
(local errors-panel (require :fen.extensions.tui.panels.errors))
(local input (require :fen.extensions.tui.input))

(local M {})

;; ---------- color presets ----------

(local C
  {:user      (bor tb.CYAN tb.BOLD)
   :assistant tb.GREEN
   :tool      tb.YELLOW
   :err       (bor tb.RED tb.BOLD)
   :dim       (bor tb.WHITE tb.DIM)
   :status-fg (bor tb.WHITE tb.REVERSE)
   :status-bg tb.DEFAULT
   :prompt    (bor tb.CYAN tb.BOLD)
   :normal    tb.DEFAULT})

;; ---------- defensive state init ----------
;;
;; Each subsystem owns its own backfill — this orchestrator just calls
;; them all so callers don't need to know the layout. New fields are
;; added to the subsystem that owns them, not here.

;; @doc fen.extensions.tui.paint.ensure-state-defaults!
;; kind: function
;; signature: (ensure-state-defaults!) -> nil
;; summary: Backfill persistent paint, transcript, status, errors, spinner, and input defaults after reloads.
;; tags: tui paint state reload
(fn M.ensure-state-defaults! []
  "Fill in state fields that may be missing on a live state table
   predating them (e.g. after /reload adds a new field)."
  (redraw.ensure-defaults!)
  (transcript.ensure-defaults!)
  (status-panel.ensure-defaults!)
  (errors-panel.ensure-defaults!)
  (input.ensure-defaults!))

;; @doc fen.extensions.tui.paint.max-scroll
;; kind: function
;; signature: (max-scroll) -> number
;; summary: Return the maximum transcript scroll offset after accounting for the current input area height.
;; tags: tui paint scroll transcript
(fn M.max-scroll []
  "Total wrapped line count minus the visible region. Used to clamp PgUp."
  (transcript.max-scroll (input.input-rows)))

;; ---------- layout ----------
;;
;; Layout is a placement walker: status row owns y=0, input rows own the
;; bottom. :below-status panels stack downward from y=1, lower :order
;; closer to the status row. :above-input panels stack upward from
;; (input-y0 - 1), lower :order closer to the input. Transcript fills
;; the band that's left over.
;;
;; Panel slots is a list of `{:name :y0 :y1 :height :render}` records
;; ordered top-to-bottom, suitable for paint-panels to walk.

(fn collect-panels [placement ctx]
  (let [out []
        panels (if state.api (state.api.list :panels) [])]
    (each [_ p (ipairs panels)]
      (when (= p.placement placement)
        (let [(ok? h) (pcall p.height ctx)
              h* (if ok? (math.max 0 (math.floor (or h 0))) 1)]
          (when (> h* 0)
            (table.insert out {:name p.name :height h* :render p.render})))))
    out))

(fn place-below [panels budget]
  "Stack `panels` (already :order-sorted) downward starting at y=1.
   Returns (slots used) where slots is a list of {:name :y0 :y1 :height :render}."
  (let [slots []]
    (var y 1)
    (var used 0)
    (each [_ p (ipairs panels)]
      (let [remaining (- budget used)
            take (math.max 0 (math.min p.height remaining))]
        (when (> take 0)
          (table.insert slots
                        {:name p.name :y0 y :y1 (+ y take -1)
                         :height take :render p.render})
          (set y (+ y take))
          (set used (+ used take)))))
    (values slots used)))

(fn place-above [panels budget bottom-row]
  "Stack `panels` (already :order-sorted, lower order = closer to input)
   upward from `bottom-row`. Returns (slots used) where slots is a list
   ordered as inserted — first slot is the bottommost (closest to input)."
  (let [slots []]
    (var bottom bottom-row)
    (var used 0)
    (each [_ p (ipairs panels)]
      (let [remaining (- budget used)
            take (math.max 0 (math.min p.height remaining))]
        (when (> take 0)
          (table.insert slots
                        {:name p.name :y0 (- bottom take -1) :y1 bottom
                         :height take :render p.render})
          (set bottom (- bottom take))
          (set used (+ used take)))))
    (values slots used)))

;; @doc fen.extensions.tui.paint.layout
;; kind: function
;; signature: (layout) -> Layout
;; summary: Compute status, transcript, input, and registered panel slots for the current terminal dimensions.
;; tags: tui paint layout panels
(fn M.layout []
  (let [w state.tb-cols
        h state.tb-rows
        input-h (input.input-rows)
        status-y 0
        ctx {:w w :status-info state.status-info :state state}
        below (collect-panels :below-status ctx)
        above (collect-panels :above-input ctx)
        below-budget (math.max 0 (- h 1 input-h))
        (below-slots below-used) (place-below below below-budget)
        above-budget (math.max 0 (- h 1 input-h below-used))
        (above-slots _) (place-above above above-budget (- h input-h 1))
        transcript-y0 (+ 1 below-used)
        ;; Topmost above-input panel sits at (last slot's y0). If no
        ;; above-input panels, transcript runs to (input-y0 - 1).
        first-above-y0 (if (> (length above-slots) 0)
                           (. above-slots (length above-slots) :y0)
                           (- h input-h))
        transcript-y1 (- first-above-y0 1)]
    {: w : h
     : status-y
     :below-status-panels below-slots
     :above-input-panels above-slots
     : transcript-y0 : transcript-y1
     :input-y0 (- h input-h)
     :input-y1 (- h 1)
     :transcript-h (math.max 0 (+ 1 (- transcript-y1 transcript-y0)))
     : input-h}))

;; ---------- low-level paint helpers (from draw.fnl) ----------

(local put-clipped draw.put-clipped)
(local fill-row draw.fill-row)

;; ---------- formatting helpers ----------

(fn fmt-tokens [n]
  "Compact token formatter: 12 → \"12\", 1234 → \"1.2k\", 12345 → \"12k\",
   1234567 → \"1.2M\". Used to keep the status line scannable when totals
   reach hundreds of thousands."
  (let [n (or n 0)]
    (if (< n 1000) (tostring n)
        (< n 10000) (string.format "%.1fk" (/ n 1000))
        (< n 1000000) (string.format "%dk" (math.floor (/ n 1000)))
        (string.format "%.1fM" (/ n 1000000)))))

;; @doc fen.extensions.tui.paint.fmt-tokens
;; kind: data
;; signature: function
;; summary: Compact token-count formatter alias used by status renderers and tests.
;; tags: tui paint status tokens
(set M.fmt-tokens fmt-tokens)

;; Status paint moved to panels/status.fnl; delegate so existing callers
;; keep using paint.paint-status.
;; @doc fen.extensions.tui.paint.paint-status
;; kind: function
;; signature: (paint-status layout) -> nil
;; summary: Delegate status-line painting to the status panel module while preserving the paint facade entrypoint.
;; tags: tui paint status delegate
(fn M.paint-status [lay] (status-panel.paint lay))

(fn put-row [row y width]
  "Paint a flat or segment-aware transcript row. Segment rows are used by the
   Markdown renderer for inline bold/italic spans. Rows may carry :bg to make
   a full-width band, used for scannable user messages."
  (let [bg (or row.bg C.normal)]
    (when row.bg
      (fill-row y 0 (- width 1) 32 C.normal bg))
    (if row.segments
        (do
          (var x 0)
          (each [_ seg (ipairs row.segments)]
            (let [remaining (- width x)]
              (when (> remaining 0)
                (put-clipped x y (or seg.attr row.attr C.normal) (or seg.bg bg)
                             (or seg.text "") remaining)
                (set x (+ x (math.min remaining (md.display-len (or seg.text "")))))))))
        (put-clipped 0 y row.attr bg row.text width))))

;; ---------- panel painting ----------
;;
;; Render each reserved panel slot (computed by M.layout). Per-slot pcall
;; isolation: a render error prints a one-line `panel-error:<name> <msg>`
;; and the frame continues, mirroring rendered-status-items's policy.

(fn panel-attr [style]
  (if (= style :error) C.err
      (= style :user) C.user
      (= style :assistant) C.assistant
      (= style :tool) C.tool
      (= style :dim) C.dim
      C.normal))

(fn paint-panel-rows [slot rows]
  (var i 0)
  (each [_ row (ipairs rows)]
    (when (< i slot.height)
      (let [y (+ slot.y0 i)
            r {:text (or row.text "")
               :attr (or row.attr (panel-attr row.style))
               :bg row.bg
               :segments row.segments}]
        (put-row r y state.tb-cols))
      (set i (+ i 1))))
  ;; No need to clear unused rows: paint-frame! calls tb.clear before painting
  ;; every dirty frame, so clearing here only adds Lua→C work on slow terminals.
  nil)

(fn paint-panel-error [slot err]
  (when (> slot.height 0)
    (fill-row slot.y0 0 (- state.tb-cols 1) 32 C.err C.normal)
    (put-clipped 0 slot.y0 C.err C.normal
                 (.. "panel-error:" (tostring slot.name) " " (tostring err))
                 state.tb-cols)))

;; @doc fen.extensions.tui.paint.paint-panels
;; kind: function
;; signature: (paint-panels layout) -> nil
;; summary: Render registered above-input and below-status panels with per-panel error isolation.
;; tags: tui paint panels errors
(fn M.paint-panels [lay]
  (let [ctx {:w lay.w :status-info state.status-info :state state}]
    (each [_ slot (ipairs lay.below-status-panels)]
      (let [(ok? rows) (pcall slot.render ctx)]
        (if ok? (paint-panel-rows slot (or rows []))
            (paint-panel-error slot rows))))
    (each [_ slot (ipairs lay.above-input-panels)]
      (let [(ok? rows) (pcall slot.render ctx)]
        (if ok? (paint-panel-rows slot (or rows []))
            (paint-panel-error slot rows))))))

;; @doc fen.extensions.tui.paint.paint-transcript
;; kind: function
;; signature: (paint-transcript layout) -> nil
;; summary: Paint the visible transcript viewport rows into the reserved transcript region.
;; tags: tui paint transcript viewport
(fn M.paint-transcript [{: w : transcript-y0 : transcript-y1 : transcript-h}]
  (let [rows (transcript.viewport-lines w transcript-h)
        n (length rows)]
    ;; Clear any rows we won't paint (so old content from a /new doesn't linger).
    ;; tb.clear() at top of redraw already wipes the back buffer, so this is
    ;; redundant here but cheap.
    (for [i 1 n]
      (let [row (. rows i)
            y (+ transcript-y0 (- i 1))]
        (when (<= y transcript-y1)
          (put-row row y w))))))

;; @doc fen.extensions.tui.paint.paint-input
;; kind: function
;; signature: (paint-input layout) -> nil
;; summary: Delegate to the input renderer for the reserved input region.
;; tags: tui paint input delegate
(fn M.paint-input [lay]
  (input.paint-input lay))

;; ---------- redraw scheduling ----------

;; @doc fen.extensions.tui.paint.invalidate!
;; kind: function
;; signature: (invalidate!) -> nil
;; summary: Mark the TUI dirty so the next presenter-loop pass repaints the terminal.
;; tags: tui paint redraw dirty
(fn M.invalidate! []
  "Mark the TUI as needing a repaint on the next presenter-loop pass."
  (redraw.invalidate!))

;; @doc fen.extensions.tui.paint.invalidate-full!
;; kind: function
;; signature: (invalidate-full!) -> nil
;; summary: Request a cache-clearing repaint for resize, reload, and display toggles that invalidate wrapped rows.
;; tags: tui paint redraw cache
(fn M.invalidate-full! []
  "Request a cache-clearing repaint. Used for resize/reload/display toggles
   where wrapped transcript rows or termbox front-buffer assumptions may be stale."
  (redraw.invalidate-full!))

;; @doc fen.extensions.tui.paint.busy?
;; kind: function
;; signature: (busy?) -> boolean|string|nil
;; summary: Report whether thinking or tool-running status should keep the busy animation active.
;; tags: tui paint busy status
(fn M.busy? []
  (redraw.ensure-defaults!)
  (or state.status-info.thinking? state.status-info.running-label))

;; @doc fen.extensions.tui.paint.advance-spinner-if-due!
;; kind: function
;; signature: (advance-spinner-if-due!) -> nil
;; summary: Advance the status spinner on a throttled presenter-loop tick cadence and invalidate when it changes.
;; tags: tui paint spinner animation
(fn M.advance-spinner-if-due! []
  "Advance the busy spinner at a low cadence measured in presenter-loop ticks.
   The loop already wakes for cooperative agent work; counting those ticks avoids
   adding a wall-clock dependency while preventing 33 FPS spinner redraws."
  (redraw.ensure-defaults!)
  (if (and state.animations? (M.busy?))
      (do
        (set state.spinner-ticks (+ (or state.spinner-ticks 0) 1))
        (when (>= state.spinner-ticks (or state.spinner-interval-ticks 8))
          (set state.spinner-ticks 0)
          (set state.status-info.spin-frame (+ (or state.status-info.spin-frame 0) 1))
          (set state.dirty? true)))
      (set state.spinner-ticks 0)))

;; @doc fen.extensions.tui.paint.redraw-if-needed!
;; kind: function
;; signature: (redraw-if-needed!) -> nil
;; summary: Repaint only when dirty or forced, clearing caches and terminal geometry before forced redraws.
;; tags: tui paint redraw performance
(fn M.redraw-if-needed! []
  "Paint only when invalidated. force-redraw? first blank-presents and clears
   transcript render caches, then the normal frame repaint presents the new UI."
  (redraw.ensure-defaults!)
  (when (and state.tb-initialized? (or state.dirty? state.force-redraw?))
    (let [force? state.force-redraw?]
      (set state.dirty? false)
      (set state.force-redraw? false)
      (when force?
        (M.clear-render-caches!)
        (set state.tb-cols (math.max 1 (tb.width)))
        (set state.tb-rows (math.max 1 (tb.height)))
        (tb.clear)
        (tb.present))
      (M.redraw!))))

;; @doc fen.extensions.tui.paint.paint-frame!
;; kind: function
;; signature: (paint-frame!) -> nil
;; summary: Paint a complete frame into the termbox back buffer without presenting, allowing overlays to share the underlay.
;; tags: tui paint frame termbox
(fn M.paint-frame! []
  "Paint one full frame into termbox's back buffer without presenting it.
   Modal overlays use this so they can draw the normal UI underneath and
   present only once, avoiding underlay/overlay flicker."
  (when state.tb-initialized?
    ;; Keep our cached geometry in sync even before a pending resize event is
    ;; drained. This avoids painting with stale, too-large dimensions if a
    ;; redraw is triggered immediately after SIGWINCH.
    (set state.tb-cols (math.max 1 (tb.width)))
    (set state.tb-rows (math.max 1 (tb.height)))
    (tb.clear)
    (let [lay (M.layout)]
      (M.paint-status lay)
      (M.paint-transcript lay)
      (M.paint-panels lay)
      (M.paint-input lay))))

;; @doc fen.extensions.tui.paint.redraw!
;; kind: function
;; signature: (redraw!) -> nil
;; summary: Paint a complete TUI frame and present termbox's back buffer to the terminal.
;; tags: tui paint redraw termbox
(fn M.redraw! []
  (when state.tb-initialized?
    (M.paint-frame!)
    (tb.present)))

;; @doc fen.extensions.tui.paint.clear-render-caches!
;; kind: function
;; signature: (clear-render-caches!) -> nil
;; summary: Drop transcript render caches so forced repaints or reloads recompute rows with current renderers.
;; tags: tui paint cache transcript
(fn M.clear-render-caches! []
  "Drop cached rendered rows so a forced repaint or /reload recomputes all
   transcript presentation with the currently loaded renderer."
  (M.ensure-state-defaults!)
  (transcript.clear-render-caches!))

;; @doc fen.extensions.tui.paint.force-redraw!
;; kind: function
;; signature: (force-redraw!) -> nil
;; summary: Blank-present and repaint the full terminal to resynchronize termbox front-buffer assumptions.
;; tags: tui paint redraw termbox
(fn M.force-redraw! []
  "Force a full terminal repaint. The blank present invalidates termbox2's
   front-buffer assumptions; the following redraw paints the real frame."
  (when state.tb-initialized?
    (M.clear-render-caches!)
    (set state.tb-cols (math.max 1 (tb.width)))
    (set state.tb-rows (math.max 1 (tb.height)))
    (tb.clear)
    (tb.present)
    (set state.dirty? false)
    (set state.force-redraw? false)
    (M.redraw!)))

M
