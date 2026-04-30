;; TUI render code: layout, transcript composition, paint regions, redraw.
;;
;; Issue #15 Step 3d split — extracted from `extensions.tui` so the only
;; file in the TUI extension that touches the api (`core.extensions`) is
;; `init.fnl`. paint.fnl never imports the api; it only reads/writes the
;; `extensions.tui.state` table and draws via termbox2.
;;
;; Hot-reload note: in RELOADABLE; manual-reload! mutates this module's
;; exports in place so callers (init.fnl, input.fnl) keep the same
;; module-table reference and pick up new paint code on the next call.

(local state (require :extensions.tui.state))
(local tb (require :termbox2))
(local md (require :extensions.tui.markdown))
(local transcript (require :extensions.tui.panels.transcript))
(local extensions (require :core.extensions))

(local M {})

;; Pre-register so a circular require from extensions.tui.input (which
;; needs paint.put-clipped, paint.max-scroll, paint.redraw!) returns this
;; partial module instead of nil. Required because input.fnl now owns
;; input painting and is required by paint.fnl below.
(tset package.loaded :extensions.tui.paint M)

(local input (require :extensions.tui.input))

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

(set M.TOOL-RESULT-PREVIEW-BYTES transcript.TOOL-RESULT-PREVIEW-BYTES)

;; ---------- transcript module re-exports ----------
;; init.fnl and tests reach into paint.X for tool-call formatters and
;; helpers. After the panels/transcript.fnl extraction we re-export those
;; here so existing callers don't need to know the new module path.
(set M.args->string transcript.args->string)
(set M.content->text transcript.content->text)
(set M.truncate transcript.truncate)
(set M.count-lines transcript.count-lines)
(set M.lookup-tool-call transcript.lookup-tool-call)
(set M.tool-call-short transcript.tool-call-short)
(set M.split-lines transcript.split-lines)
(set M.viewport-lines transcript.viewport-lines)

;; ---------- defensive state init ----------

(fn M.ensure-state-defaults! []
  "Fill in any state fields that may be missing — useful when /reload
   adds new fields but the live state table predates them."
  (when (= state.transcript nil) (set state.transcript []))
  (when (= state.scroll-offset nil) (set state.scroll-offset 0))
  (when (= state.input-buf nil) (set state.input-buf ""))
  (when (= state.input-cursor nil) (set state.input-cursor 0))
  (when (= state.history nil) (set state.history []))
  (when (= state.history-pos nil) (set state.history-pos 0))
  (when (= state.history-draft nil) (set state.history-draft ""))
  (when (= state.pending-quit? nil) (set state.pending-quit? false))
  (when (= state.cancel-pressed? nil) (set state.cancel-pressed? false))
  (when (= state.expand-tool-results? nil) (set state.expand-tool-results? false))
  (when (= state.markdown? nil) (set state.markdown? true))
  (when (= state.hide-thinking-block? nil) (set state.hide-thinking-block? false))
  (when (= state.status-info nil)
    (set state.status-info
         {:model nil :provider nil
          :cum-input 0 :cum-output 0 :cum-cache-read 0 :cum-cache-write 0
          :last-input 0
          :steering-queued 0 :follow-up-queued 0
          :start-ms 0 :running-label nil :thinking? false :cancelling? false}))
  ;; Backfill new token-accounting fields onto pre-existing status-info
  ;; tables (e.g. after /reload added them).
  (let [s state.status-info]
    (when (= s.cum-input nil)       (set s.cum-input 0))
    (when (= s.cum-output nil)      (set s.cum-output 0))
    (when (= s.cum-cache-read nil)  (set s.cum-cache-read 0))
    (when (= s.cum-cache-write nil) (set s.cum-cache-write 0))
    (when (= s.last-input nil)      (set s.last-input 0))
    (when (= s.cancelling? nil)     (set s.cancelling? false))
    (when (= s.steering-queued nil) (set s.steering-queued 0))
    (when (= s.follow-up-queued nil) (set s.follow-up-queued 0))
    (when (= s.turn-start nil)      (set s.turn-start 0))
    (when (= s.spin-frame nil)       (set s.spin-frame 0))
    ;; Migrate the old running-tool key → running-label for live state
    ;; that predates the rename.
    (when (and (= s.running-label nil) (. s :running-tool))
      (set s.running-label (. s :running-tool)))
    (when (= s.running-label nil)    (set s.running-label nil))))

(fn M.max-scroll []
  "Total wrapped line count minus the visible region. Used to clamp PgUp."
  (transcript.max-scroll (M.input-rows)))

;; ---------- input region delegates ----------
;; input.fnl owns input wrapping, cursor positioning, and paint-input.

(set M.input-display-rows input.input-display-rows)
(set M.cursor-display-pos input.cursor-display-pos)
(fn M.input-rows [] (input.input-rows))

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
  (let [out []]
    (each [_ p (ipairs (extensions.list :panels))]
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

(fn M.layout []
  (let [w state.tb-cols
        h state.tb-rows
        input-h (M.input-rows)
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

;; ---------- low-level paint helpers ----------

(fn in-bounds? [x y]
  (and (>= x 0) (< x state.tb-cols)
       (>= y 0) (< y state.tb-rows)))

(fn fill-row [y x0 x1 ch fg bg]
  (when (and (>= y 0) (< y state.tb-rows))
    (let [x0* (math.max 0 x0)
          x1* (math.min (- state.tb-cols 1) x1)]
      (when (<= x0* x1*)
        (for [x x0* x1*]
          (tb.set_cell x y ch fg bg))))))

(fn utf8-prefix-cols [s cols]
  "Return a prefix of s containing at most cols UTF-8 codepoints. This is
   still an approximation (wide CJK and combining marks are not measured),
   but it avoids cutting box-drawing/bullet characters mid-byte and lets
   Markdown chrome span the intended terminal width."
  (let [text (or s "")
        limit (math.max 0 (or cols 0))]
    (var i 1)
    (var used 0)
    (var end 0)
    (while (and (<= i (length text)) (< used limit))
      (let [b (string.byte text i)
            step (if (< b 128) 1
                     (< b 224) 2
                     (< b 240) 3
                     4)
            next-i (+ i step)]
        (when (<= (- next-i 1) (length text))
          (set end (- next-i 1))
          (set used (+ used 1)))
        (set i next-i)))
    (string.sub text 1 end)))

(fn put-clipped [x y fg bg s width-cap]
  "Print s starting at x,y but cap at width-cap columns.
   tb_print returns OUT_OF_BOUNDS when the starting coordinate is off-screen,
   so guard here; this matters during very small terminal resize events."
  (when (and (> (or width-cap 0) 0) (in-bounds? x y))
    (let [remaining (- state.tb-cols x)
          cap (math.max 0 (math.min width-cap remaining))
          s* (utf8-prefix-cols s cap)]
      (when (> cap 0)
        (tb.print x y fg bg s*)))))

(set M.put-clipped put-clipped)
(set M.in-bounds? in-bounds?)
(set M.fill-row fill-row)
(set M.utf8-prefix-cols utf8-prefix-cols)

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

(set M.fmt-tokens fmt-tokens)

;; Status paint moved to panels/status.fnl; delegate so existing callers
;; keep using paint.paint-status.

(local status-panel (require :extensions.tui.panels.status))
(fn M.paint-status [lay] (status-panel.paint lay))

(fn put-row [row y width]
  "Paint a flat or segment-aware transcript row. Segment rows are used by the
   Markdown renderer for inline bold/italic spans."
  (if row.segments
      (do
        (var x 0)
        (each [_ seg (ipairs row.segments)]
          (let [remaining (- width x)]
            (when (> remaining 0)
              (put-clipped x y (or seg.attr row.attr C.normal) C.normal
                           (or seg.text "") remaining)
              (set x (+ x (math.min remaining (md.display-len (or seg.text "")))))))))
      (put-clipped 0 y row.attr C.normal row.text width)))

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
               :segments row.segments}]
        (put-row r y state.tb-cols))
      (set i (+ i 1))))
  (while (< i slot.height)
    (let [y (+ slot.y0 i)]
      (fill-row y 0 (- state.tb-cols 1) 32 C.normal C.normal))
    (set i (+ i 1))))

(fn paint-panel-error [slot err]
  (when (> slot.height 0)
    (fill-row slot.y0 0 (- state.tb-cols 1) 32 C.err C.normal)
    (put-clipped 0 slot.y0 C.err C.normal
                 (.. "panel-error:" (tostring slot.name) " " (tostring err))
                 state.tb-cols)))

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

(fn M.paint-transcript [{: w : transcript-y0 : transcript-y1 : transcript-h}]
  (let [rows (M.viewport-lines w transcript-h)
        n (length rows)]
    ;; Clear any rows we won't paint (so old content from a /new doesn't linger).
    ;; tb.clear() at top of redraw already wipes the back buffer, so this is
    ;; redundant here but cheap.
    (for [i 1 n]
      (let [row (. rows i)
            y (+ transcript-y0 (- i 1))]
        (when (<= y transcript-y1)
          (put-row row y w))))))

(fn M.paint-input [lay] (input.paint-input lay))

;; ---------- redraw ----------

(fn M.redraw! []
  (when state.tb-initialized?
    ;; Keep our cached geometry in sync even before a pending resize event is
    ;; drained. This avoids painting with stale, too-large dimensions if a
    ;; redraw is triggered immediately after SIGWINCH.
    (set state.tb-cols (math.max 1 (tb.width)))
    (set state.tb-rows (math.max 1 (tb.height)))
    ;; Advance the spinner frame while busy so the braille dot animates.
    (when (or state.status-info.thinking? state.status-info.running-label)
      (set state.status-info.spin-frame (+ (or state.status-info.spin-frame 0) 1)))
    (tb.clear)
    (let [lay (M.layout)]
      (M.paint-status lay)
      (M.paint-transcript lay)
      (M.paint-panels lay)
      (M.paint-input lay))
    (tb.present)))

(fn M.clear-render-caches! []
  "Drop cached rendered rows so a forced repaint or /reload recomputes all
   transcript presentation with the currently loaded renderer."
  (M.ensure-state-defaults!)
  (transcript.clear-render-caches!))

(fn M.force-redraw! []
  "Force a full terminal repaint. The blank present invalidates termbox2's
   front-buffer assumptions; the following redraw paints the real frame."
  (when state.tb-initialized?
    (M.clear-render-caches!)
    (set state.tb-cols (math.max 1 (tb.width)))
    (set state.tb-rows (math.max 1 (tb.height)))
    (tb.clear)
    (tb.present)
    (M.redraw!)))

M
