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
(local json (require :util.json))
(local tb (require :termbox2))
(local md (require :extensions.tui.markdown))

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

(local INPUT-ROWS-MAX 5)
(set M.TOOL-RESULT-PREVIEW-BYTES 1024)

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

;; ---------- formatting helpers (run at append time, cached on the event) ----------

(fn M.args->string [args]
  (if (= (type args) :string) args
      (= args nil) "{}"
      (let [(ok? s) (pcall json.encode args)]
        (if ok? s "{}"))))

(fn M.content->text [content]
  "Concatenate text blocks of an AgentToolResult content list."
  (if (= content nil) ""
      (let [parts []]
        (each [_ b (ipairs content)]
          (when (= b.type :text)
            (table.insert parts (or b.text ""))))
        (table.concat parts ""))))

(fn M.truncate [s n]
  (if (<= (length s) n) s
      (.. (string.sub s 1 n) " …(truncated)")))

(fn M.count-lines [s]
  "Count \\n-terminated lines plus a trailing partial line if present."
  (if (or (= s nil) (= s "")) 0
      (do (var n 0)
          (var i 1)
          (let [len (length s)]
            (while (<= i len)
              (let [j (string.find s "\n" i true)]
                (set n (+ n 1))
                (if j
                    (set i (+ j 1))
                    (set i (+ len 1))))))
          n)))

(fn fmt-bytes [n]
  "Human-readable byte count: 312 → 312B, 8400 → 8.2KB, 2_500_000 → 2.4MB."
  (let [n (or n 0)]
    (if (< n 1024) (.. (tostring n) "B")
        (< n (* 1024 1024)) (string.format "%.1fKB" (/ n 1024))
        (string.format "%.1fMB" (/ n (* 1024 1024))))))

(fn fmt-duration [seconds]
  "Compact wall-clock duration for tool summaries."
  (let [s (tonumber seconds)]
    (if (= s nil) ""
        (<= s 0) "<1s"
        (< s 60) (.. (tostring (math.floor s)) "s")
        (string.format "%dm%02ds" (math.floor (/ s 60)) (% (math.floor s) 60)))))

(fn M.lookup-tool-call [tool-call-id]
  "Walk back through state.transcript to find the matching :tool-call
   event for a result. Transcript is small; linear scan is fine."
  (when tool-call-id
    (var found nil)
    (var i (length state.transcript))
    (while (and (> i 0) (= found nil))
      (let [ev (. state.transcript i)]
        (when (and (= ev.type :tool-call)
                   (or (= ev.id tool-call-id)
                       (= ev.tool-call-id tool-call-id)))
          (set found ev)))
      (set i (- i 1)))
    found))

;; ---------- line wrapping ----------

(fn split-lines [s]
  "Split on \\n into a list, preserving empty lines."
  (let [out []]
    (var i 1)
    (let [n (length s)]
      (while (<= i n)
        (let [j (string.find s "\n" i true)]
          (if j
              (do (table.insert out (string.sub s i (- j 1)))
                  (set i (+ j 1)))
              (do (table.insert out (string.sub s i n))
                  (set i (+ n 1))))))
      (when (or (= n 0) (= (string.sub s n n) "\n"))
        (table.insert out "")))
    out))

(set M.split-lines split-lines)

(fn hard-wrap-line [line width]
  "Wrap a single (no-\\n) line into chunks of at most `width` bytes.
   Byte-based wrapping; UTF-8 codepoints spanning a wrap boundary will
   be visually broken. Acceptable for Phase 1; Phase 2 can do wcwidth."
  (let [width* (math.max 1 width)]
    (if (= line "")
        [""]
        (let [out []
              n (length line)]
          (var i 1)
          (while (<= i n)
            (table.insert out (string.sub line i (+ i width* -1)))
            (set i (+ i width*)))
          out))))

(fn wrap-text [s width]
  "Multi-line wrap. Splits on \\n, then hard-wraps each piece."
  (let [out []]
    (each [_ line (ipairs (split-lines s))]
      (each [_ chunk (ipairs (hard-wrap-line line width))]
        (table.insert out chunk)))
    out))

;; ---------- per-tool short-form formatters ----------

(fn fmt-read [a]
  (let [path (or a.path "?")
        off a.offset
        lim a.limit]
    (if (or off lim)
        (let [start (or off 1)
              end (if lim (+ start lim -1) "")]
          (.. "read " path ":" (tostring start) "-" (tostring end)))
        (.. "read " path))))

(fn fmt-bash [a]
  (.. "$ " (or a.cmd "")
      (if a.timeout (.. " (timeout " (tostring a.timeout) "s)") "")))

(fn fmt-edit [a] (.. "edit " (or a.path "?")))
(fn fmt-write [a] (.. "write " (or a.path "?")))

(fn fmt-ls [a]
  (.. "ls " (or a.path ".")
      (if a.limit (.. " (limit " (tostring a.limit) ")") "")))

(fn fmt-grep [a]
  (.. "grep /" (or a.pattern "") "/ in " (or a.path ".")
      (if a.glob (.. " (" a.glob ")") "")
      (if a.limit (.. " limit " (tostring a.limit)) "")))

(fn fmt-find [a]
  (.. "find " (or a.pattern "") " in " (or a.path ".")
      (if a.limit (.. " limit " (tostring a.limit)) "")))

(fn M.tool-call-short [name args]
  "Compact tool-call header per built-in. Falls back to nil for unknown
   tools (caller drops back to JSON args)."
  (let [a (or args {})
        n (string.lower (tostring (or name "")))]
    (if (= n :bash) (fmt-bash a)
        (= n :read) (fmt-read a)
        (= n :write) (fmt-write a)
        (= n :edit) (fmt-edit a)
        (= n :ls) (fmt-ls a)
        (= n :grep) (fmt-grep a)
        (= n :find) (fmt-find a)
        nil)))

(fn tool-result-summary [ev]
  "One-line collapsed summary for a :tool-result event. Tool name and
   path come from the matching :tool-call (stashed at append time).
   is-error? flips the success glyph for edit/write."
  (let [name (string.lower (tostring (or ev.tool-name "tool")))
        bytes (or ev.body-bytes 0)
        lines (or ev.body-lines 0)
        duration (fmt-duration ev.duration-seconds)
        suffix (if (not= duration "") (.. ", " duration) "")
        err? ev.is-error?
        path ev.tool-path]
    (if (or (= name :edit) (= name :write))
        (.. name (if path (.. " " path) "") (if err? " ✗" " ✓") suffix)
        (.. name " (" (tostring lines) " lines, " (fmt-bytes bytes) suffix ")"))))

;; ---------- transcript event → display lines ----------

(fn lines-for-event [ev width]
  "Returns a list of {:text :attr} display rows for a transcript event.
   For :assistant-text events, when state.markdown? is true, renders
   through the Markdown renderer for styled output."
  (let [rows []
        push (fn [text attr indent?]
               (each [_ chunk (ipairs (wrap-text text width))]
                 (table.insert rows {:text (if indent? (.. "     " chunk) chunk)
                                     :attr attr})))
        push-hanging (fn [prefix text attr]
                       (let [p (or prefix "")
                             body-w (math.max 1 (- width (length p)))
                             cont (string.rep " " (length p))]
                         (var first? true)
                         (each [_ chunk (ipairs (wrap-text (or text "") body-w))]
                           (table.insert rows
                                         {:text (.. (if first? p cont) chunk)
                                          :attr attr})
                           (set first? false))))]
    (if (= ev.type :user)
        (push (.. "you> " (or ev.text "")) C.user false)

        (= ev.type :assistant-text)
        (do
          (if state.markdown?
              ;; Markdown rendering: keep the same gutter behavior as the old
              ;; plain renderer — only the first visual row gets "ai>  ". Later
              ;; explicit lines start at column 0 instead of being indented by a
              ;; synthetic continuation gutter.
              (let [body-w width]
                (when (or (not ev.md-cache-lines)
                          (not= ev.md-cache-width body-w))
                  (set ev.md-cache-width body-w)
                  (set ev.md-cache-lines (md.render-text (or ev.text "") body-w)))
                (var i 0)
                (each [_ ml (ipairs ev.md-cache-lines)]
                  (set i (+ i 1))
                  (let [prefix (if (= i 1) "ai>  " "")
                        attr (or ml.attr C.assistant)]
                    (if ml.segments
                        (let [segments []]
                          (when (not= prefix "")
                            (table.insert segments {:text prefix :attr attr}))
                          (each [_ seg (ipairs ml.segments)]
                            (table.insert segments seg))
                          (table.insert rows
                                        {:text (.. prefix (or ml.text ""))
                                         :attr attr
                                         :segments segments}))
                        (table.insert rows
                                      {:text (.. prefix (or ml.text ""))
                                       :attr attr})))))
              ;; Plain rendering (original behavior)
              (push (.. "ai>  " (or ev.text "")) C.assistant false))
          (when ev.spacer-after?
            (table.insert rows {:text "" :attr C.dim})))

        (= ev.type :assistant-thinking)
        (do
          (if state.hide-thinking-block?
              (push "…   Thinking..." C.dim false)
              state.markdown?
              (let [body-w width]
                (when (or (not ev.md-cache-lines)
                          (not= ev.md-cache-width body-w))
                  (set ev.md-cache-width body-w)
                  (set ev.md-cache-lines (md.render-text (or ev.text "") body-w)))
                (var i 0)
                (each [_ ml (ipairs ev.md-cache-lines)]
                  (set i (+ i 1))
                  (let [prefix (if (= i 1) "…   " "")]
                    (table.insert rows
                                  {:text (.. prefix (or ml.text ""))
                                   :attr C.dim}))))
              (push (.. "…   " (or ev.text "")) C.dim false))
          (when ev.spacer-after?
            (table.insert rows {:text "" :attr C.dim})))

        (= ev.type :info)
        (push (or ev.text "") C.dim false)

        (= ev.type :queued)
        (push (.. "queued> " (tostring (or ev.queue "")) ": " (or ev.text "")) C.dim false)

        (= ev.type :steering-injected)
        (push (.. "steer> " (or ev.text "")) C.user false)

        (= ev.type :follow-up-injected)
        (push (.. "next> " (or ev.text "")) C.user false)

        (= ev.type :tool-call)
        (push-hanging "tool> "
                      (or ev.short
                          (.. (tostring ev.name) " " (or ev.args-pretty "{}")))
                      C.tool)

        (= ev.type :tool-result)
        (if (or state.expand-tool-results? ev.expanded?)
            (push (or ev.body-pretty "") C.dim true)
            (push-hanging "tool< " (tool-result-summary ev) C.dim))

        (= ev.type :error)
        (push (.. "err> " (tostring ev.error)) C.err false)

        (= ev.type :cancelled)
        (push "⊘  cancelled by user" C.dim false)

        ;; Unknown event: render raw.
        (push (.. (tostring ev.type) ": " (tostring (or ev.text ev.error "")))
              C.dim false))
    rows))

;; ---------- viewport composition ----------

(fn M.viewport-lines [width region-h]
  "Returns up to region-h display rows {text,attr} ending at the tail of
   the transcript (modulo state.scroll-offset). Wraps only events that
   intersect the viewport — does not pre-render the entire log."
  (let [need (+ region-h state.scroll-offset)
        ;; Walk transcript backward, prepending rows until we have `need`
        ;; rows or run out of events.
        collected []]
    (var idx (length state.transcript))
    (while (and (> idx 0) (< (length collected) need))
      (let [ev (. state.transcript idx)
            rows (lines-for-event ev width)]
        ;; Prepend in reverse so the natural order is preserved.
        (var i (length rows))
        (while (> i 0)
          (table.insert collected 1 (. rows i))
          (set i (- i 1))))
      (set idx (- idx 1)))
    ;; Slice: take rows [length-region-h-scroll-offset+1, length-scroll-offset]
    (let [total (length collected)
          end-idx (- total state.scroll-offset)
          start-idx (math.max 1 (- end-idx (- region-h 1)))
          out []]
      (when (and (> end-idx 0) (>= end-idx start-idx))
        (for [i start-idx end-idx]
          (table.insert out (. collected i))))
      out)))

(fn M.max-scroll []
  "Maximum useful scroll-offset given current state — the total wrapped
   line count of the entire transcript, minus the visible region. Used
   to clamp PgUp."
  (let [w state.tb-cols
        h (- state.tb-rows 1 (M.input-rows))] ;; status + input
    (var n 0)
    (each [_ ev (ipairs state.transcript)]
      (set n (+ n (length (lines-for-event ev w)))))
    (math.max 0 (- n (math.max 1 h)))))

;; ---------- input display wrapping ----------

(fn M.input-display-rows [buf width cursor]
  "Return wrapped input display rows.

   Rows carry byte offsets into `buf` so cursor positioning can use the same
   wrapped view that painting uses. The first visual row gets the prompt; every
   subsequent visual row (soft wrap or explicit newline) gets a continuation
   marker. Wrapping is byte-based, matching the rest of this TUI's Phase-1
   rendering assumptions."
  (let [prompt-w 2
        cont-w 2
        first-text-w (math.max 1 (- width prompt-w))
        cont-text-w (math.max 1 (- width cont-w))
        lines (split-lines buf)
        rows []]
    (var pos 0)     ;; byte offset of the start of the current logical line
    (var first? true)
    (each [line-idx line (ipairs lines)]
      (let [line-start pos
            line-n (length line)]
        (if (= line-n 0)
            (do
              (table.insert rows {:text "" :start line-start :end line-start
                                  :first? first?})
              (set first? false))
            (do
              (var off 0)
              (while (< off line-n)
                (let [avail (if first? first-text-w cont-text-w)
                      take (math.min avail (- line-n off))
                      chunk-start (+ line-start off)
                      chunk-end (+ chunk-start take)]
                  (table.insert rows
                                {:text (string.sub line (+ off 1) (+ off take))
                                 :start chunk-start
                                 :end chunk-end
                                 :first? first?})
                  (set first? false)
                  (set off (+ off take))))
              ;; If the insertion point is exactly after a full visual row,
              ;; show it at the beginning of the next wrapped row instead of
              ;; trying to place the terminal cursor one column past the edge.
              (let [last-row (. rows (length rows))]
                (when (and (= cursor (+ line-start line-n))
                           last-row
                           (= (length last-row.text)
                              (if last-row.first? first-text-w cont-text-w)))
                  (table.insert rows {:text "" :start cursor :end cursor
                                      :first? false}))))))
      ;; Account for the explicit newline byte between logical lines.
      (set pos (+ pos (length line)))
      (when (< line-idx (length lines))
        (set pos (+ pos 1))))
    (when (= (length rows) 0)
      (table.insert rows {:text "" :start 0 :end 0 :first? true}))
    rows))

(fn M.cursor-display-pos [rows cursor]
  "Return (row-index-0, col) for cursor in wrapped input rows. At soft-wrap
   boundaries, prefer the later row so the cursor visually wraps."
  (var row-idx 0)
  (var col 0)
  (each [i row (ipairs rows)]
    (when (and (>= cursor row.start) (<= cursor row.end))
      (set row-idx (- i 1))
      (set col (math.min (length row.text) (- cursor row.start)))))
  (values row-idx col))

(fn M.input-rows []
  "Number of rows the input area occupies, capped at INPUT-ROWS-MAX. Long
   logical lines soft-wrap using the current terminal width."
  (let [w (math.max 1 (or state.tb-cols 1))]
    (math.min INPUT-ROWS-MAX
              (math.max 1 (length (M.input-display-rows state.input-buf
                                                         w
                                                         state.input-cursor))))))

;; ---------- layout ----------

(fn M.layout []
  (let [w state.tb-cols
        h state.tb-rows
        input-h (M.input-rows)
        status-y 0
        ;; Reserve one row above the input for the busy indicator
        ;; (spinner + timer). Shown whether or not the agent is running;
        ;; idle leaves the row blank (acts as a visual separator).
        busy-y (- h input-h 1)
        input-y0 (- h input-h)
        transcript-y0 1
        transcript-y1 (- busy-y 1)]
    {: w : h
     : status-y
     : busy-y
     : transcript-y0 : transcript-y1
     : input-y0
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

;; ---------- spinner + timer ----------

(local SPINNER-FRAMES ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])

(fn M.spin-char []
  (let [s state.status-info
        frame (or s.spin-frame 0)
        idx (+ (% frame (length SPINNER-FRAMES)) 1)]
    (or (. SPINNER-FRAMES idx) "⠋")))

(fn M.turn-elapsed []
  "Seconds since the current turn started, or empty string when idle."
  (let [s state.status-info
        start (or s.turn-start 0)]
    (if (= start 0) ""
        (.. (tostring (- (os.time) start)) "s"))))

(fn fmt-tokens [n]
  "Compact token formatter: 12 → \"12\", 1234 → \"1.2k\", 12345 → \"12k\",
   1234567 → \"1.2M\". Used to keep the status line scannable when totals
   reach hundreds of thousands."
  (let [n (or n 0)]
    (if (< n 1000) (tostring n)
        (< n 10000) (string.format "%.1fk" (/ n 1000))
        (< n 1000000) (string.format "%dk" (math.floor (/ n 1000)))
        (string.format "%.1fM" (/ n 1000000)))))

(fn M.paint-status [{: w : status-y}]
  (fill-row status-y 0 (- w 1) 32 C.status-fg C.status-bg)
  (let [s state.status-info
        provider (or s.provider "?")
        model (or s.model "?")
        busy-label (if state.pending-quit? "ctrl-c again to quit"
                       s.cancelling? "cancelling…"
                       "")
        line (.. " " provider ":" (tostring model)
                 "  ctx:" (fmt-tokens s.last-input)
                 (if (> (or s.steering-queued 0) 0)
                     (.. "  steer:" (tostring s.steering-queued))
                     "")
                 (if (> (or s.follow-up-queued 0) 0)
                     (.. "  follow:" (tostring s.follow-up-queued))
                     "")
                 (if (not= busy-label "") (.. "  " busy-label) "")
                 (if (> state.scroll-offset 0)
                     (.. "  scrolled:" (tostring state.scroll-offset))
                     ""))]
    (put-clipped 0 status-y C.status-fg C.status-bg line w)))

(fn M.paint-busy [{: w : busy-y}]
  "Paint the busy indicator row above the input box: spinner, label,
   and elapsed timer when the agent is running. Blank when idle."
  (fill-row busy-y 0 (- w 1) 32 C.normal C.normal)
  (let [s state.status-info
        busy-label (or s.running-label (if s.thinking? "thinking" ""))]
    (when (not= busy-label "")
      (let [elapsed (M.turn-elapsed)
            spin (M.spin-char)
            text (.. "  " spin " " busy-label (if (not= elapsed "") (.. "  " elapsed) ""))]
        (put-clipped 0 busy-y C.dim C.normal text w)))))

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

(fn M.paint-input [{: w : input-y0 : input-y1 : input-h}]
  ;; Prompt on the first visual row; subsequent visual rows (soft wraps and
  ;; explicit newlines) get blank padding aligned under the prompt — quieter
  ;; than the dot-leader continuation marker we used to draw.
  (let [prompt "> "
        cont "  "
        prompt-w (length prompt)
        cont-w (length cont)
        rows (M.input-display-rows state.input-buf w state.input-cursor)
        (cur-row cur-col) (M.cursor-display-pos rows state.input-cursor)
        first-visible (math.max 0 (- cur-row (- input-h 1)))
        last-visible (math.min (- (length rows) 1) (+ first-visible (- input-h 1)))]
    (for [i 0 (- input-h 1)]
      (let [row-idx (+ first-visible i)
            row (if (<= row-idx last-visible)
                    (. rows (+ row-idx 1))
                    nil)
            y (+ input-y0 i)
            first? (and row row.first?)
            prefix (if first? prompt cont)
            prefix-w (if first? prompt-w cont-w)
            text-w (math.max 1 (- w prefix-w))]
        (put-clipped 0 y (if first? C.prompt C.dim) C.normal prefix prefix-w)
        (put-clipped prefix-w y C.normal C.normal (or (?. row :text) "") text-w)))
    ;; Cursor positioning.
    (let [screen-row (- cur-row first-visible)
          row (. rows (+ cur-row 1))
          prefix-w (if (and row row.first?) prompt-w cont-w)
          cur-x (+ prefix-w cur-col)
          cur-y (+ input-y0 screen-row)]
      (if (and (>= screen-row 0) (< screen-row input-h) (< cur-x w))
          (tb.set_cursor cur-x cur-y)
          (tb.hide_cursor)))))

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
      (M.paint-busy lay)
      (M.paint-input lay))
    (tb.present)))

(fn M.clear-render-caches! []
  "Drop cached rendered rows so a forced repaint or /reload recomputes all
   transcript presentation with the currently loaded renderer."
  (M.ensure-state-defaults!)
  (each [_ ev (ipairs state.transcript)]
    (set ev.md-cache-lines nil)
    (set ev.md-cache-width nil)))

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
