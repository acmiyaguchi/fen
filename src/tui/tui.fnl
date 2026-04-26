;; Full-screen TUI backed by termbox2.
;;
;; Layout (top to bottom):
;;   row 0      status line: agent-fennel | provider:model | tokens:N | Ts | tool:NAME
;;   row 1      hrule
;;   row 2..    transcript region (scrollable; auto-tails unless scrolled up)
;;   row H-K-1  hrule
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
   :hrule     (bor tb.WHITE tb.DIM)
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
  (when (= state.status-info nil)
    (set state.status-info
         {:model nil :provider nil :total-tokens 0
          :start-ms 0 :running-tool nil :thinking? false})))

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
  (if (= line "")
      [""]
      (let [out []
            n (length line)]
        (var i 1)
        (while (<= i n)
          (table.insert out (string.sub line i (+ i width -1)))
          (set i (+ i width)))
        out)))

(fn wrap-text [s width]
  "Multi-line wrap. Splits on \\n, then hard-wraps each piece."
  (let [out []]
    (each [_ line (ipairs (split-lines s))]
      (each [_ chunk (ipairs (hard-wrap-line line width))]
        (table.insert out chunk)))
    out))

;; ---------- transcript event → display lines ----------

(fn lines-for-event [ev width]
  "Returns a list of {:text :attr} display rows for a transcript event."
  (let [rows []
        push (fn [text attr indent?]
               (each [_ chunk (ipairs (wrap-text text width))]
                 (table.insert rows {:text (if indent? (.. "     " chunk) chunk)
                                     :attr attr})))]
    (if (= ev.type :user)
        (push (.. "you> " (or ev.text "")) C.user false)

        (= ev.type :assistant-text)
        (push (.. "ai>  " (or ev.text "")) C.assistant false)

        (= ev.type :tool-call)
        (push (.. "tool> " (tostring ev.name) " " (or ev.args-pretty "{}"))
              C.tool false)

        (= ev.type :tool-result)
        (push (or ev.body-pretty "") C.dim true)

        (= ev.type :error)
        (push (.. "err> " (tostring ev.error)) C.err false)

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
        h (- state.tb-rows 2 (M.input-rows) 2)] ;; status + 2 hrules + input
    (var n 0)
    (each [_ ev (ipairs state.transcript)]
      (set n (+ n (length (lines-for-event ev w)))))
    (math.max 0 (- n (math.max 1 h)))))

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
  "Number of rows the input area occupies, capped at INPUT-ROWS-MAX."
  (var rows 1)
  (each [_ (string.gmatch state.input-buf "\n")]
    (set rows (+ rows 1)))
  (math.min INPUT-ROWS-MAX (math.max 1 rows)))

;; ---------- layout ----------

(fn M.layout []
  (let [w state.tb-cols
        h state.tb-rows
        input-h (M.input-rows)
        status-y 0
        hrule1-y 1
        input-y0 (- h input-h)
        hrule2-y (- input-y0 1)
        transcript-y0 2
        transcript-y1 (- hrule2-y 1)]
    {: w : h
     : status-y : hrule1-y
     : transcript-y0 : transcript-y1
     : hrule2-y
     : input-y0
     :input-y1 (- h 1)
     :transcript-h (math.max 0 (+ 1 (- transcript-y1 transcript-y0)))
     : input-h}))

;; ---------- low-level paint helpers ----------

(fn fill-row [y x0 x1 ch fg bg]
  (for [x x0 x1]
    (tb.set_cell x y ch fg bg)))

(fn put-clipped [x y fg bg s width-cap]
  "Print s starting at x,y but cap at width-cap columns. termbox already
   silently drops out-of-bounds writes, so cap is mostly defensive."
  (let [s* (if (and width-cap (> (length s) width-cap))
               (string.sub s 1 width-cap)
               s)]
    (tb.print x y fg bg s*)))

;; ---------- paint regions ----------

(fn elapsed-string []
  (let [s state.status-info
        start (or s.start-ms 0)]
    (if (= start 0) "0s"
        (.. (tostring (- (os.time) start)) "s"))))

(fn M.paint-status [{: w : status-y}]
  (fill-row status-y 0 (- w 1) 32 C.status-fg C.status-bg)
  (let [s state.status-info
        provider (or s.provider "?")
        model (or s.model "?")
        tokens (or s.total-tokens 0)
        running (or s.running-tool (if s.thinking? "thinking" ""))
        line (.. " agent-fennel  "
                 provider ":" (tostring model)
                 "  tokens:" (tostring tokens)
                 "  " (elapsed-string)
                 (if (and running (not= running ""))
                     (.. "  busy:" running)
                     "")
                 (if (> state.scroll-offset 0)
                     (.. "  scrolled:" (tostring state.scroll-offset))
                     ""))]
    (put-clipped 0 status-y C.status-fg C.status-bg line w)))

(fn M.paint-hrule [y w]
  (fill-row y 0 (- w 1) 0x2500 C.hrule C.normal))  ;; U+2500 BOX DRAWINGS LIGHT HORIZONTAL

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
          (put-clipped 0 y row.attr C.normal row.text w))))))

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
  ;; Prompt on the first input row; subsequent rows indent to align.
  (let [prompt "> "
        prompt-w (length prompt)
        text-w (math.max 1 (- w prompt-w))
        lines (split-lines state.input-buf)
        ;; Determine the visible window of input lines: if cursor is on
        ;; line `cur-line`, scroll to keep it in [0, input-h).
        (cur-line cur-col) (cursor-line-col state.input-buf state.input-cursor)
        first-visible (math.max 0 (- cur-line (- input-h 1)))
        last-visible (math.min (- (length lines) 1) (+ first-visible (- input-h 1)))]
    (put-clipped 0 input-y0 C.prompt C.normal prompt prompt-w)
    (for [i 0 (- input-h 1)]
      (let [line-idx (+ first-visible i)
            y (+ input-y0 i)
            x (if (= i 0) prompt-w prompt-w)
            content (if (<= line-idx last-visible)
                        (or (. lines (+ line-idx 1)) "")
                        "")]
        (when (= i 0)
          (put-clipped x y C.normal C.normal "" 0))
        (when (not= i 0)
          (put-clipped 0 y C.dim C.normal ".. " 3))
        (put-clipped (if (= i 0) prompt-w 3) y C.normal C.normal content text-w)))
    ;; Cursor positioning.
    (let [cur-row (- cur-line first-visible)
          cur-x (+ (if (= cur-row 0) prompt-w 3) cur-col)
          cur-y (+ input-y0 cur-row)]
      (if (and (>= cur-row 0) (< cur-row input-h))
          (tb.set_cursor cur-x cur-y)
          (tb.hide_cursor)))))

;; ---------- redraw ----------

(fn M.redraw! []
  (when state.tb-initialized?
    (tb.clear)
    (let [lay (M.layout)]
      (M.paint-status lay)
      (M.paint-hrule lay.hrule1-y lay.w)
      (M.paint-transcript lay)
      (M.paint-hrule lay.hrule2-y lay.w)
      (M.paint-input lay))
    (tb.present)))

;; ---------- event ingestion ----------

(fn M.append-event [ev]
  (M.ensure-state-defaults!)
  ;; Status-info side effects (don't pollute the transcript).
  (if (= ev.type :llm-start)
      (set state.status-info.thinking? true)

      (= ev.type :llm-end)
      (do (set state.status-info.thinking? false)
          (when (and ev.usage ev.usage.total-tokens)
            (set state.status-info.total-tokens
                 (+ (or state.status-info.total-tokens 0)
                    ev.usage.total-tokens))))

      (= ev.type :tool-call)
      (do (set state.status-info.running-tool (tostring ev.name))
          ;; Also pre-stringify args for transcript rendering.
          (set ev.args-pretty (args->string ev.arguments))
          (table.insert state.transcript ev))

      (= ev.type :tool-result)
      (do (set state.status-info.running-tool nil)
          (let [text (content->text (?. ev :result :content))]
            (set ev.body-pretty (truncate text TOOL-RESULT-PREVIEW-BYTES)))
          (table.insert state.transcript ev))

      ;; user / assistant-text / error / unknown — just append.
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
  (let [(line _) (cursor-line-col state.input-buf state.input-cursor)]
    (if (= line 0)
        (history-prev)
        (let [(_ col) (cursor-line-col state.input-buf state.input-cursor)
              lines (split-lines state.input-buf)
              prev-line (or (. lines line) "")
              prev-len (length prev-line)
              ;; byte offset of start of (line-1) (0-indexed)
              target-col (math.min col prev-len)]
          ;; Find byte offset by re-walking
          (var off 0)
          (for [i 1 (- line 1)]
            (set off (+ off (length (or (. lines i) "")) 1)))
          (set state.input-cursor (+ off target-col))))))

(fn cursor-down-or-history []
  (let [(line _) (cursor-line-col state.input-buf state.input-cursor)
        lines (split-lines state.input-buf)
        last-line (- (length lines) 1)]
    (if (>= line last-line)
        (history-next)
        (let [(_ col) (cursor-line-col state.input-buf state.input-cursor)
              next-l (or (. lines (+ line 2)) "")
              target-col (math.min col (length next-l))]
          (var off 0)
          (for [i 1 (+ line 1)]
            (set off (+ off (length (or (. lines i) "")) 1)))
          (set state.input-cursor (+ off target-col))))))

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

(fn M.handle-key [ev on-submit]
  "Mutates state in response to a single key event. Returns true if the
   event requests session quit."
  (M.ensure-state-defaults!)
  (let [k ev.key
        m (or ev.mod 0)
        ch ev.ch]
    ;; Reset pending-quit on any non-Ctrl-C key.
    (when (and state.pending-quit? (not= k tb.KEY_CTRL_C))
      (set state.pending-quit? false))
    (if
      ;; ----- submit / newline -----
      (= k tb.KEY_ENTER)
      (do (submit! on-submit) false)

      (= k tb.KEY_CTRL_J)
      (do (insert-text "\n") false)

      ;; ----- quit -----
      (= k tb.KEY_CTRL_D)
      true

      (= k tb.KEY_CTRL_C)
      (if (and state.status-info.running-tool
               (not state.pending-quit?))
          ;; In Phase 1 we don't have a real abort signal; surface a hint.
          (do (M.append-event
                {:type :error
                 :error "ctrl-c during tool: abort not yet supported (Phase 2)"})
              false)
          (and (not= state.input-buf "") (not state.pending-quit?))
          (do (set state.input-buf "")
              (set state.input-cursor 0)
              (set state.history-pos 0)
              false)
          state.pending-quit?
          true
          (do (set state.pending-quit? true)
              (M.append-event {:type :error
                               :error "press ctrl-c again to quit (or ctrl-d)"})
              false))

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

(fn M.handle-event [ev on-submit]
  (if (= ev.type tb.EVENT_RESIZE)
      (do (set state.tb-cols (math.max 1 ev.w))
          (set state.tb-rows (math.max 1 ev.h))
          false)
      (= ev.type tb.EVENT_KEY)
      (M.handle-key ev on-submit)
      ;; Mouse / unknown: ignore for Phase 1.
      false))

;; ---------- lifecycle ----------

(fn M.init! []
  (M.ensure-state-defaults!)
  (when (not state.tb-initialized?)
    (let [(rc _err _code) (tb.init)]
      (if (and rc (>= rc 0))
          (do (set state.tb-initialized? true)
              (set state.tb-init-failed? false)
              (set state.tb-cols (tb.width))
              (set state.tb-rows (tb.height))
              (when (= state.status-info.start-ms 0)
                (set state.status-info.start-ms (os.time)))
              ;; INPUT_ALT collapses ESC+key into one event with MOD_ALT.
              (tb.set_input_mode tb.INPUT_ALT)
              (tb.set_output_mode tb.OUTPUT_NORMAL))
          (do (set state.tb-init-failed? true)
              (set state.tb-initialized? false))))))

(fn M.shutdown []
  (when state.tb-initialized?
    (tb.shutdown)
    (set state.tb-initialized? false)))

(fn M.set-status-info [info]
  "Optional: caller (main.fnl) can populate provider/model on the status
   line. Falls back to nil → '?' rendering otherwise."
  (M.ensure-state-defaults!)
  (when info.provider (set state.status-info.provider info.provider))
  (when info.model (set state.status-info.model info.model)))

(fn M.run [on-submit]
  (when state.tb-init-failed?
    (io.stderr:write
      "agent-fennel: termbox2 init failed (TUI requires an interactive terminal)\n")
    (os.exit 1))
  (M.append-event
    {:type :assistant-text
     :text "agent-fennel — ctrl-d to quit, ctrl-c twice to quit, ctrl-j for newline"})
  (var quit? false)
  (while (not quit?)
    (M.redraw!)
    (let [(ev err _code) (tb.poll_event)]
      (if (= ev nil)
          (do (M.append-event
                {:type :error
                 :error (.. "tb_poll_event failed: " (tostring err))})
              (set quit? true))
          (let [(ok? r) (pcall M.handle-event ev on-submit)]
            (if (not ok?)
                (M.append-event {:type :error
                                 :error (.. "tui: " (tostring r))})
                r
                (set quit? true)))))))

M
