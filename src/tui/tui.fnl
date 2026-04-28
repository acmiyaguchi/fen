;; Full-screen TUI backed by termbox2.
;;
;; Layout (top to bottom):
;;   row 0      status line: provider:model | ctx:N | busy:tool | scrolled:N
;;   row 1..    transcript region (scrollable; auto-tails unless scrolled up)
;;   row H-K..  multi-line input box (K rows; grows with newlines, capped)
;;
;; Hot-reload note: every helper is a field on the module table `M`, and
;; internal calls dispatch through `M.<name>` so a /reload that mutates
;; this module table picks up new code on the next call. Mutable state
;; lives in `tui.state` (NOT reloaded) — termbox2 binds process-global C
;; state, so its initialized? flag must persist across reloads, otherwise
;; shutdown would skip teardown and leave the terminal wedged.
;;
;; Termbox2 itself maintains a back/front buffer with internal diffing,
;; so we don't carry our own diff layer: every redraw clears, repaints,
;; and presents. Cheap enough to call on every keystroke and event.

(local state (require :tui.state))
(local json (require :util.json))
(local tb (require :termbox2))
(local md (require :tui.markdown))

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
(local TOOL-RESULT-PREVIEW-BYTES 1024)

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
    (when (= s.turn-start nil)      (set s.turn-start 0))
    (when (= s.spin-frame nil)       (set s.spin-frame 0))
    ;; Migrate the old running-tool key → running-label for live state
    ;; that predates the rename.
    (when (and (= s.running-label nil) (. s :running-tool))
      (set s.running-label (. s :running-tool)))
    (when (= s.running-label nil)    (set s.running-label nil))))

;; ---------- formatting helpers (run at append time, cached on the event) ----------

(fn args->string [args]
  (if (= (type args) :string) args
      (= args nil) "{}"
      (let [(ok? s) (pcall json.encode args)]
        (if ok? s "{}"))))

(fn content->text [content]
  "Concatenate text blocks of an AgentToolResult content list."
  (if (= content nil) ""
      (let [parts []]
        (each [_ b (ipairs content)]
          (when (= b.type :text)
            (table.insert parts (or b.text ""))))
        (table.concat parts ""))))

(fn truncate [s n]
  (if (<= (length s) n) s
      (.. (string.sub s 1 n) " …(truncated)")))

(fn count-lines [s]
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

(fn lookup-tool-call [tool-call-id]
  "Walk back through state.transcript to find the matching :tool-call
   event for a result. Transcript is small; linear scan is fine."
  (when tool-call-id
    (var found nil)
    (var i (length state.transcript))
    (while (and (> i 0) (= found nil))
      (let [ev (. state.transcript i)]
        (when (and (= ev.type :tool-call) (= ev.tool-call-id tool-call-id))
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

(fn tool-call-short [name args]
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
        err? ev.is-error?
        path ev.tool-path]
    (if (or (= name :edit) (= name :write))
        (.. "← " name (if path (.. " " path) "") (if err? " ✗" " ✓"))
        (.. "← " name
            " (" (tostring lines) " lines, " (fmt-bytes bytes) ")"))))

;; ---------- transcript event → display lines ----------

(fn lines-for-event [ev width]
  "Returns a list of {:text :attr} display rows for a transcript event.
   For :assistant-text events, when state.markdown? is true, renders
   through the Markdown renderer for styled output."
  (let [rows []
        push (fn [text attr indent?]
               (each [_ chunk (ipairs (wrap-text text width))]
                 (table.insert rows {:text (if indent? (.. "     " chunk) chunk)
                                     :attr attr})))]
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

        (= ev.type :tool-call)
        (push (or ev.short
                  (.. "tool> " (tostring ev.name) " " (or ev.args-pretty "{}")))
              C.tool false)

        (= ev.type :tool-result)
        (if (or state.expand-tool-results? ev.expanded?)
            (push (or ev.body-pretty "") C.dim true)
            (push (tool-result-summary ev) C.dim false))

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

(fn input-display-rows [buf width cursor]
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

(fn cursor-display-pos [rows cursor]
  "Return (row-index-0, col) for cursor in wrapped input rows. At soft-wrap
   boundaries, prefer the later row so the cursor visually wraps."
  (var row-idx 0)
  (var col 0)
  (each [i row (ipairs rows)]
    (when (and (>= cursor row.start) (<= cursor row.end))
      (set row-idx (- i 1))
      (set col (math.min (length row.text) (- cursor row.start)))))
  (values row-idx col))

;; ---------- input buffer line bounds ----------

(fn line-bounds [buf cursor]
  "Returns (line-start, line-end-exclusive) byte offsets of the line
   containing `cursor`. line-end is the index of the next \\n or #buf."
  (let [n (length buf)
        ;; line start: scan backward from cursor for \n
        start (or (if (> cursor 0)
                      (let [(s _) (string.find (string.sub buf 1 cursor)
                                               "\n[^\n]*$")]
                        (if s s nil))
                      nil)
                  0)
        ;; line end: scan forward for next \n
        end (or (string.find buf "\n" (+ cursor 1) true)
                (+ n 1))]
    (values start (- end 1))))

(fn M.input-rows []
  "Number of rows the input area occupies, capped at INPUT-ROWS-MAX. Long
   logical lines soft-wrap using the current terminal width."
  (let [w (math.max 1 (or state.tb-cols 1))]
    (math.min INPUT-ROWS-MAX
              (math.max 1 (length (input-display-rows state.input-buf
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

;; ---------- paint regions ----------

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

(fn buf-line [buf line-idx]
  "Return the `line-idx`-th line (0-indexed) of buf, splitting on \\n."
  (let [lines (split-lines buf)]
    (or (. lines (+ line-idx 1)) "")))

(fn cursor-line-col [buf cursor]
  "Convert a byte cursor into (line-index, column-bytes-into-that-line)."
  (var line 0)
  (var col 0)
  (var i 1)
  (while (<= i cursor)
    (if (= (string.sub buf i i) "\n")
        (do (set line (+ line 1)) (set col 0))
        (set col (+ col 1)))
    (set i (+ i 1)))
  (values line col))

(fn M.paint-input [{: w : input-y0 : input-y1 : input-h}]
  ;; Prompt on the first visual row; subsequent visual rows (soft wraps and
  ;; explicit newlines) get blank padding aligned under the prompt — quieter
  ;; than the dot-leader continuation marker we used to draw.
  (let [prompt "> "
        cont "  "
        prompt-w (length prompt)
        cont-w (length cont)
        rows (input-display-rows state.input-buf w state.input-cursor)
        (cur-row cur-col) (cursor-display-pos rows state.input-cursor)
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

;; ---------- event ingestion ----------

(fn clear-render-cache! [ev]
  (set ev.md-cache-lines nil)
  (set ev.md-cache-width nil))

(fn find-streaming-assistant-row [row-type content-index]
  (var found nil)
  (var i (length state.transcript))
  (while (and (> i 0) (not found))
    (let [ev (. state.transcript i)]
      (if (and ev ev.streaming? (= ev.type row-type)
               (= ev.content-index content-index))
          (set found ev)
          ;; Stop searching once we've crossed into an older assistant/tool/user
          ;; group. This keeps interleaved future events from mutating stale rows.
          (and ev (not ev.streaming?)
               (or (= ev.type :assistant-text)
                   (= ev.type :assistant-thinking)
                   (= ev.type :tool-call)
                   (= ev.type :tool-result)
                   (= ev.type :user)))
          (set i 0)))
    (set i (- i 1)))
  found)

(fn append-assistant-delta! [row-type content-index delta]
  (let [row (or (find-streaming-assistant-row row-type content-index)
                (let [ev {:type row-type
                          :text ""
                          :final? false
                          :streaming? true
                          :content-index content-index}]
                  (table.insert state.transcript ev)
                  ev))]
    (set row.text (.. (or row.text "") (or delta "")))
    (clear-render-cache! row)))

(fn finish-streaming-assistant! [final?]
  (var last nil)
  (each [_ ev (ipairs state.transcript)]
    (when ev.streaming?
      (set ev.streaming? nil)
      (set ev.final? false)
      (set last ev)))
  (when last
    (set last.final? final?)))

(fn M.append-event [ev]
  (M.ensure-state-defaults!)
  ;; Status-info side effects (don't pollute the transcript).
  (if (= ev.type :llm-start)
      (do (set state.status-info.thinking? true)
          ;; Stamp the turn start on the first llm-start of a turn
          ;; (turn-start is cleared when a turn completes).
          (when (= (or state.status-info.turn-start 0) 0)
            (set state.status-info.turn-start (os.time))))

      (= ev.type :llm-end)
      (do (set state.status-info.thinking? false)
          (when ev.usage
            (let [u ev.usage
                  s state.status-info]
              (set s.cum-input       (+ s.cum-input       (or u.input 0)))
              (set s.cum-output      (+ s.cum-output      (or u.output 0)))
              (set s.cum-cache-read  (+ s.cum-cache-read  (or u.cache-read 0)))
              (set s.cum-cache-write (+ s.cum-cache-write (or u.cache-write 0)))
              (set s.last-input      (or u.input s.last-input)))))

      (= ev.type :tool-call)
      (do
          ;; Compute the tailored short form for known built-ins; fall
          ;; back to JSON args for anything else. args-pretty stays as a
          ;; safety net the renderer still consults.
          (set ev.short (tool-call-short ev.name ev.arguments))
          (set ev.args-pretty (args->string ev.arguments))
          ;; running-label drives the busy indicator row. Prefer the
          ;; short form (which includes the path/cmd for built-ins) over
          ;; the bare tool name.
          (set state.status-info.running-label
               (or ev.short (tostring ev.name)))
          (table.insert state.transcript ev))

      (= ev.type :tool-result)
      (do (set state.status-info.running-label nil)
          (let [text (content->text (?. ev :result :content))
                tc (lookup-tool-call ev.tool-call-id)]
            (set ev.body-bytes (length text))
            (set ev.body-lines (count-lines text))
            (set ev.body-pretty (truncate text TOOL-RESULT-PREVIEW-BYTES))
            (set ev.tool-name (?. tc :name))
            (set ev.tool-path (?. tc :arguments :path)))
          (table.insert state.transcript ev))

      (= ev.type :cancelled)
      (do (set state.status-info.thinking? false)
          (set state.status-info.running-label nil)
          (set state.status-info.cancelling? false)
          (set state.status-info.turn-start 0)
          (table.insert state.transcript ev))

      (= ev.type :assistant-text)
      (do (when (not= ev.final? false)
            (set state.status-info.thinking? false)
            (set state.status-info.running-label nil)
            (set state.status-info.turn-start 0))
          (table.insert state.transcript ev))

      (= ev.type :assistant-thinking)
      (do (when ev.final?
            (set state.status-info.thinking? false)
            (set state.status-info.running-label nil)
            (set state.status-info.turn-start 0))
          (table.insert state.transcript ev))

      (= ev.type :assistant-text-delta)
      (append-assistant-delta! :assistant-text ev.content-index ev.delta)

      (= ev.type :assistant-thinking-delta)
      (append-assistant-delta! :assistant-thinking ev.content-index ev.delta)

      (= ev.type :assistant-stream-end)
      (do (finish-streaming-assistant! ev.final?)
          (when ev.final?
            (set state.status-info.thinking? false)
            (set state.status-info.running-label nil)
            (set state.status-info.turn-start 0)))

      (= ev.type :error)
      (do (set state.status-info.thinking? false)
          (set state.status-info.running-label nil)
          (set state.status-info.turn-start 0)
          (table.insert state.transcript ev))

      ;; user / unknown — just append.
      (table.insert state.transcript ev))
  ;; Reset scroll to tail when new content arrives, only if the user
  ;; wasn't already scrolled up.
  (when (= state.scroll-offset 0)
    (set state.scroll-offset 0))
  (M.redraw!))

;; ---------- input mutation primitives ----------

(fn prev-utf8-boundary [s pos]
  "Return the byte offset of the cursor after deleting one codepoint
   backward from `pos`. Treats UTF-8 continuation bytes (0x80..0xBF)
   as part of the preceding codepoint."
  (if (<= pos 0) 0
      (do
        (var i pos)
        (while (and (> i 1)
                    (let [b (string.byte s i)]
                      (and b (>= b 0x80) (< b 0xC0))))
          (set i (- i 1)))
        (- i 1))))

(fn next-utf8-boundary [s pos]
  "Return the byte offset just past the codepoint starting at `pos`."
  (let [n (length s)]
    (if (>= pos n) n
        (do
          (var i (+ pos 2))  ;; skip lead byte (1-indexed s[pos+1])
          (while (and (<= i n)
                      (let [b (string.byte s i)]
                        (and b (>= b 0x80) (< b 0xC0))))
            (set i (+ i 1)))
          (- i 1)))))

(fn insert-text [text]
  (let [buf state.input-buf
        c state.input-cursor
        before (string.sub buf 1 c)
        after (string.sub buf (+ c 1))]
    (set state.input-buf (.. before text after))
    (set state.input-cursor (+ c (length text)))))

(fn delete-back []
  (when (> state.input-cursor 0)
    (let [buf state.input-buf
          new-c (prev-utf8-boundary buf state.input-cursor)
          before (string.sub buf 1 new-c)
          after (string.sub buf (+ state.input-cursor 1))]
      (set state.input-buf (.. before after))
      (set state.input-cursor new-c))))

(fn cursor-left []
  (when (> state.input-cursor 0)
    (set state.input-cursor (prev-utf8-boundary state.input-buf state.input-cursor))))

(fn cursor-right []
  (when (< state.input-cursor (length state.input-buf))
    (set state.input-cursor (next-utf8-boundary state.input-buf state.input-cursor))))

(fn cursor-line-start []
  (let [(start _) (line-bounds state.input-buf state.input-cursor)]
    (set state.input-cursor start)))

(fn cursor-line-end []
  (let [(_ end) (line-bounds state.input-buf state.input-cursor)]
    (set state.input-cursor end)))

(fn kill-to-line-start []
  (let [(start _) (line-bounds state.input-buf state.input-cursor)
        buf state.input-buf
        before (string.sub buf 1 start)
        after (string.sub buf (+ state.input-cursor 1))]
    (set state.input-buf (.. before after))
    (set state.input-cursor start)))

(fn is-word-byte? [b]
  (and b (or (and (>= b 48) (<= b 57))
             (and (>= b 65) (<= b 90))
             (and (>= b 97) (<= b 122))
             (= b 95)
             (>= b 0x80))))

(fn delete-word-back []
  ;; Skip whitespace back, then delete word bytes back.
  (when (> state.input-cursor 0)
    (var c state.input-cursor)
    (let [buf state.input-buf]
      (while (and (> c 0)
                  (not (is-word-byte? (string.byte buf c))))
        (set c (- c 1)))
      (while (and (> c 0)
                  (is-word-byte? (string.byte buf c)))
        (set c (- c 1)))
      (let [before (string.sub buf 1 c)
            after (string.sub buf (+ state.input-cursor 1))]
        (set state.input-buf (.. before after))
        (set state.input-cursor c)))))

;; History navigation

(fn history-prev []
  (when (> (length state.history) 0)
    (when (= state.history-pos 0)
      (set state.history-draft state.input-buf))
    (when (< state.history-pos (length state.history))
      (set state.history-pos (+ state.history-pos 1))
      (let [entry (. state.history (- (length state.history)
                                      (- state.history-pos 1)))]
        (set state.input-buf (or entry ""))
        (set state.input-cursor (length state.input-buf))))))

(fn history-next []
  (when (> state.history-pos 0)
    (set state.history-pos (- state.history-pos 1))
    (if (= state.history-pos 0)
        (do (set state.input-buf state.history-draft)
            (set state.input-cursor (length state.input-buf)))
        (let [entry (. state.history (- (length state.history)
                                        (- state.history-pos 1)))]
          (set state.input-buf (or entry ""))
          (set state.input-cursor (length state.input-buf))))))

;; Up/Down: history at edges of buffer, otherwise navigate within buf.

(fn cursor-up-or-history []
  ;; Navigate by visual wrapped rows, not just explicit newline-delimited
  ;; logical lines. Only fall back to history when already on the top visual
  ;; row of the input.
  (let [rows (input-display-rows state.input-buf
                                 (math.max 1 (or state.tb-cols 1))
                                 state.input-cursor)
        (cur-row col) (cursor-display-pos rows state.input-cursor)]
    (if (= cur-row 0)
        (history-prev)
        (let [target (. rows cur-row) ;; cur-row is 0-based; table is 1-based.
              target-col (math.min col (length target.text))]
          (set state.input-cursor (+ target.start target-col))))))

(fn cursor-down-or-history []
  ;; Navigate by visual wrapped rows. Only fall back to history when already on
  ;; the bottom visual row of the input.
  (let [rows (input-display-rows state.input-buf
                                 (math.max 1 (or state.tb-cols 1))
                                 state.input-cursor)
        (cur-row col) (cursor-display-pos rows state.input-cursor)
        last-row (- (length rows) 1)]
    (if (>= cur-row last-row)
        (history-next)
        (let [target (. rows (+ cur-row 2))
              target-col (math.min col (length target.text))]
          (set state.input-cursor (+ target.start target-col))))))

(fn submit! [on-submit]
  (let [line state.input-buf]
    (set state.input-buf "")
    (set state.input-cursor 0)
    (set state.history-pos 0)
    (set state.history-draft "")
    (when (not= line "")
      (table.insert state.history line)
      (M.append-event {:type :user :text line})
      ;; on-submit may call agent.step which emits more events; those
      ;; will redraw on append. We catch failures so a buggy step doesn't
      ;; kill the loop.
      (let [(ok? err) (pcall on-submit line)]
        (when (not ok?)
          (M.append-event {:type :error
                           :error (.. "submit: " (tostring err))}))))))

(fn scroll-by [delta]
  (set state.scroll-offset
       (math.max 0 (math.min (M.max-scroll) (+ state.scroll-offset delta)))))

;; ---------- key dispatch ----------

(local KEY-CTRL-O 0x0f) ;; termbox2 defines this but our Lua shim doesn't export it yet.
(local KEY-CTRL-T 0x14)

(fn toggle-tool-results []
  (set state.expand-tool-results? (not state.expand-tool-results?))
  (M.redraw!))

(fn toggle-thinking-blocks []
  (set state.hide-thinking-block? (not state.hide-thinking-block?))
  (M.redraw!))

(fn M.handle-key [ev on-submit on-cancel is-busy?]
  "Mutates state in response to a single key event. Returns true if the
   event requests session quit. on-cancel and is-busy? are optional —
   when present, ctrl-c during a busy turn requests cancellation instead
   of falling into the normal two-press quit."
  (M.ensure-state-defaults!)
  (let [k ev.key
        m (or ev.mod 0)
        ch ev.ch
        busy? (and is-busy? (is-busy?))]
    ;; Reset pending-quit on any non-Ctrl-C key.
    (when (and state.pending-quit? (not= k tb.KEY_CTRL_C))
      (set state.pending-quit? false))
    (if
      ;; ----- submit / newline -----
      (= k tb.KEY_ENTER)
      (do (submit! on-submit) false)

      (= k tb.KEY_CTRL_J)
      (do (insert-text "\n") false)

      ;; ----- view toggles -----
      ;; Match pi-mono's app.tools.expand default keybinding.
      (= k KEY-CTRL-O)
      (do (toggle-tool-results) false)

      ;; Match pi-mono's app.thinking.toggle default keybinding.
      (= k KEY-CTRL-T)
      (do (toggle-thinking-blocks) false)

      ;; ----- quit -----
      (= k tb.KEY_CTRL_D)
      true

      (= k tb.KEY_CTRL_C)
      (if (and busy? state.cancel-pressed?)
          ;; Second press while still busy: force-quit. Mirrors the idle
          ;; two-press semantics so the user always has an out.
          true
          busy?
          ;; First press while busy: queue cancellation. The agent
          ;; coroutine bails at its next yield and emits :cancelled,
          ;; which the run-loop transition logic then unwinds. The
          ;; "cancelling…" hint surfaces in the status row via
          ;; status-info.cancelling?, so we don't pollute the transcript.
          (do (when on-cancel (on-cancel))
              (set state.cancel-pressed? true)
              (set state.status-info.cancelling? true)
              false)
          (and (not= state.input-buf "") (not state.pending-quit?))
          (do (set state.input-buf "")
              (set state.input-cursor 0)
              (set state.history-pos 0)
              false)
          state.pending-quit?
          true
          ;; First idle press: arm two-press quit. The hint surfaces in
          ;; the status row via state.pending-quit?; cleared on the next
          ;; non-ctrl-c keystroke.
          (do (set state.pending-quit? true) false))

      ;; ----- editing -----
      (or (= k tb.KEY_BACKSPACE) (= k tb.KEY_BACKSPACE2))
      (do (delete-back) false)

      (= k tb.KEY_CTRL_W)
      (do (delete-word-back) false)

      (= k tb.KEY_CTRL_U)
      (do (kill-to-line-start) false)

      (or (= k tb.KEY_CTRL_A) (= k tb.KEY_HOME))
      (do (cursor-line-start) false)

      (or (= k tb.KEY_CTRL_E) (= k tb.KEY_END))
      (do (cursor-line-end) false)

      (or (= k tb.KEY_CTRL_B) (= k tb.KEY_ARROW_LEFT))
      (do (cursor-left) false)

      (or (= k tb.KEY_CTRL_F) (= k tb.KEY_ARROW_RIGHT))
      (do (cursor-right) false)

      (= k tb.KEY_ARROW_UP)
      (do (cursor-up-or-history) false)

      (= k tb.KEY_ARROW_DOWN)
      (do (cursor-down-or-history) false)

      ;; Alt-P / Alt-N: unconditional history navigation (works even on
      ;; terminals where arrow keys arrive without modifiers).
      (and (= ch 0x70) (= (band m tb.MOD_ALT) tb.MOD_ALT))
      (do (history-prev) false)

      (and (= ch 0x6e) (= (band m tb.MOD_ALT) tb.MOD_ALT))
      (do (history-next) false)

      ;; Alt-P / Alt-N also surface as KEY_CTRL_P/_N + MOD_ALT on some
      ;; terminals; cover that path too.
      (and (= k tb.KEY_CTRL_P) (= (band m tb.MOD_ALT) tb.MOD_ALT))
      (do (history-prev) false)

      (and (= k tb.KEY_CTRL_N) (= (band m tb.MOD_ALT) tb.MOD_ALT))
      (do (history-next) false)

      ;; ----- scroll -----
      (= k tb.KEY_PGUP)
      (do (scroll-by (math.max 1 (math.floor (/ state.tb-rows 2)))) false)

      (= k tb.KEY_PGDN)
      (do (scroll-by (- (math.max 1 (math.floor (/ state.tb-rows 2))))) false)

      ;; ----- printable input -----
      (and (not= ch 0) (or (= k 0) (= k tb.KEY_SPACE)))
      (do (insert-text (or ev.utf8 (string.char (band ch 0xFF)))) false)

      ;; Unknown / unhandled: ignore.
      false)))

(local MOUSE-WHEEL-LINES 3)

(fn M.handle-mouse [ev]
  "Wheel up/down scrolls the transcript by MOUSE-WHEEL-LINES per notch.
   Other mouse events (clicks, drag, release) are ignored in Phase 1.
   Under tmux with `set -g mouse on`, tmux forwards SGR mouse events to
   the foreground pane while we have INPUT_MOUSE enabled."
  (let [k ev.key]
    (if (= k tb.KEY_MOUSE_WHEEL_UP)
        (do (scroll-by MOUSE-WHEEL-LINES) false)
        (= k tb.KEY_MOUSE_WHEEL_DOWN)
        (do (scroll-by (- MOUSE-WHEEL-LINES)) false)
        false)))

(fn M.handle-event [ev on-submit on-cancel is-busy?]
  (if (= ev.type tb.EVENT_RESIZE)
      (do (set state.tb-cols (math.max 1 ev.w))
          (set state.tb-rows (math.max 1 ev.h))
          (set state.scroll-offset (math.min state.scroll-offset (M.max-scroll)))
          false)
      (= ev.type tb.EVENT_KEY)
      (M.handle-key ev on-submit on-cancel is-busy?)
      (= ev.type tb.EVENT_MOUSE)
      (M.handle-mouse ev)
      false))

;; ---------- lifecycle ----------

(fn M.init! []
  "Initialize termbox2 (gated by tb-initialized? — runs at most once per
   process) and apply runtime config (idempotent — runs on every call so
   /reload can pick up new input/output mode flags or other runtime
   settings without a process restart). The /reload handler in
   src/core/commands.fnl invokes this after re-requiring tui.tui."
  (M.ensure-state-defaults!)
  (when (not state.tb-initialized?)
    (let [(rc _err _code) (tb.init)]
      (if (and rc (>= rc 0))
          (do (set state.tb-initialized? true)
              (set state.tb-init-failed? false)
              (when (= state.status-info.start-ms 0)
                (set state.status-info.start-ms (os.time))))
          (set state.tb-init-failed? true))))
  (when state.tb-initialized?
    ;; Re-cache dims (resize may have changed them) and re-assert input/output
    ;; modes. tb.set_input_mode immediately emits the SGR-mouse enable/disable
    ;; escape sequences, so changing flags here actually flips the terminal's
    ;; reporting mode mid-session. Caveat: new symbols added to the C shim
    ;; (e.g. extra TB_KEY_* constants) still require a process restart, since
    ;; package.loaded["termbox2"] is cached for the process lifetime.
    (set state.tb-cols (tb.width))
    (set state.tb-rows (tb.height))
    ;; INPUT_ALT collapses ESC+key into one event with MOD_ALT.
    ;; INPUT_MOUSE enables SGR mouse reporting (mode 1006), which tmux
    ;; forwards to the foreground pane when `set -g mouse on`.
    (tb.set_input_mode (bor tb.INPUT_ALT tb.INPUT_MOUSE))
    (tb.set_output_mode tb.OUTPUT_NORMAL)))

(fn M.shutdown []
  (when state.tb-initialized?
    (tb.shutdown)
    (set state.tb-initialized? false)))

(fn M.reset-conversation! []
  "Clear per-conversation TUI state for /new while preserving process/UI
   settings that should survive a fresh session (provider/model, dimensions,
   input history, termbox lifecycle)."
  (M.ensure-state-defaults!)
  (let [s state.status-info
        provider s.provider
        model s.model]
    (set state.transcript [])
    (set state.scroll-offset 0)
    (set state.input-buf "")
    (set state.input-cursor 0)
    (set state.history-pos 0)
    (set state.history-draft "")
    (set state.pending-quit? false)
    (set s.provider provider)
    (set s.model model)
    (set s.cum-input 0)
    (set s.cum-output 0)
    (set s.cum-cache-read 0)
    (set s.cum-cache-write 0)
    (set s.last-input 0)
    (set s.start-ms (os.time))
    (set s.running-label nil)
    (set s.thinking? false)
    (set s.turn-start 0)
    (set s.spin-frame 0))
  (M.redraw!))

(fn M.set-status-info [info]
  "Optional: caller (main.fnl) can populate provider/model on the status
   line. Falls back to nil → '?' rendering otherwise."
  (M.ensure-state-defaults!)
  (when info.provider (set state.status-info.provider info.provider))
  (when info.model (set state.status-info.model info.model)))

(local TICK-MS 30)

(fn M.run [on-submit on-tick on-cancel is-busy?]
  (when state.tb-init-failed?
    (io.stderr:write
      "agent-fennel: termbox2 init failed (TUI requires an interactive terminal)\n")
    (os.exit 1))
  (M.append-event
    {:type :info
     :text "agent-fennel — ctrl-d to quit, ctrl-c twice to quit, ctrl-j for newline"})
  (var quit? false)
  (while (not quit?)
    (M.redraw!)
    (let [(ev err code) (tb.peek_event TICK-MS)]
      (if (and (= ev nil) (= code tb.ERR_NO_EVENT))
          nil
          (= ev nil)
          (do (M.append-event
                {:type :error
                 :error (.. "tb_peek_event failed: " (tostring err))})
              (set quit? true))
          (let [(ok? r) (pcall M.handle-event ev on-submit on-cancel is-busy?)]
            (if (not ok?)
                (M.append-event {:type :error
                                 :error (.. "tui: " (tostring r))})
                r
                (set quit? true)))))
    (when (and (not quit?) on-tick)
      (let [(ok? err) (pcall on-tick)]
        (when (not ok?)
          (M.append-event {:type :error
                           :error (.. "on-tick: " (tostring err))}))))
    ;; Once the agent turn ends (busy → not busy), reset the cancel-pressed
    ;; double-tap flag so a stale press from the previous turn doesn't
    ;; force-quit on the next one. Status indicator is cleared by
    ;; append-event when :cancelled fires; this mop-up handles the case
    ;; where the turn completed normally between presses.
    (when (and state.cancel-pressed? is-busy? (not (is-busy?)))
      (set state.cancel-pressed? false)
      (set state.status-info.cancelling? false))))

M
