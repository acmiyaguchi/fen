;; TUI input handling: buffer mutation, history navigation, key dispatch.
;;
;; Issue #15 Step 3d split — extracted from `extensions.tui` so the input
;; layer is isolated from frame orchestration. Input owns view-aware cursor
;; navigation and input-region painting; redraw scheduling goes through the
;; tiny redraw leaf module, while bus events use core.extensions.
;;
;; Hot-reload note: in RELOADABLE; manual-reload! mutates this module's
;; exports in place so callers (init.fnl's M.run loop) keep the same
;; module-table reference.

(local state (require :fen.extensions.tui.state))
(local tb (require :termbox2))
(local redraw (require :fen.extensions.tui.redraw))
(local draw (require :fen.extensions.tui.draw))
(local transcript (require :fen.extensions.tui.panels.transcript))
(local command-registry (require :fen.core.extensions.register.command))

(local M {})

;; ---------- input region geometry + painting ----------
;; Owns input-display-rows / cursor-display-pos / input-rows / paint-input.
;; Moved from paint.fnl so the input region's wrapping math, cursor
;; positioning, and painting all live alongside the key/buffer code.

(local INPUT-ROWS-MAX 5)

;; Local color presets for paint-input. Mirrors paint.fnl's C; kept local
;; here so input rendering doesn't need a backplane import for the basic
;; cyan/dim/default attrs.
(local IC
  {:dim    (bor tb.WHITE tb.DIM)
   :prompt (bor tb.CYAN tb.BOLD)
   :normal tb.DEFAULT})

;; @doc fen.extensions.tui.input.ensure-defaults!
;; kind: function
;; signature: (ensure-defaults!) -> nil
;; summary: Backfill persistent input buffer, paste, history, quit, cancel, and Alt state fields after hot reloads.
;; tags: tui input state reload
(fn M.ensure-defaults! []
  "Backfill input-region state fields that may be missing on a live
   state table predating their introduction (e.g. after /reload)."
  (when (= state.input-buf nil) (set state.input-buf ""))
  (when (= state.input-cursor nil) (set state.input-cursor 0))
  (when (= state.paste-active? nil) (set state.paste-active? false))
  (when (= state.paste-buffer nil) (set state.paste-buffer ""))
  (when (= state.paste-counter nil) (set state.paste-counter 0))
  (when (= state.pastes nil) (set state.pastes {}))
  (when (= state.history nil) (set state.history []))
  (when (= state.history-pos nil) (set state.history-pos 0))
  (when (= state.history-draft nil) (set state.history-draft ""))
  (when (= state.pending-quit? nil) (set state.pending-quit? false))
  (when (= state.cancel-pressed? nil) (set state.cancel-pressed? false))
  (when (= state.alt-pending? nil) (set state.alt-pending? false))
  (when (= state.last-user-jump-index nil) (set state.last-user-jump-index nil)))

;; @doc fen.extensions.tui.input.input-display-rows
;; kind: function
;; signature: (input-display-rows buf width cursor) -> [InputDisplayRow]
;; summary: Wrap the input buffer into prompt and continuation rows that preserve byte offsets for cursor placement.
;; tags: tui input wrapping cursor
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
        lines (transcript.split-lines buf)
        rows []]
    (var pos 0)
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
              (let [last-row (. rows (length rows))]
                (when (and (= cursor (+ line-start line-n))
                           last-row
                           (= (length last-row.text)
                              (if last-row.first? first-text-w cont-text-w)))
                  (table.insert rows {:text "" :start cursor :end cursor
                                      :first? false}))))))
      (set pos (+ pos (length line)))
      (when (< line-idx (length lines))
        (set pos (+ pos 1))))
    (when (= (length rows) 0)
      (table.insert rows {:text "" :start 0 :end 0 :first? true}))
    rows))

;; @doc fen.extensions.tui.input.cursor-display-pos
;; kind: function
;; signature: (cursor-display-pos rows cursor) -> row-index col
;; summary: Locate the cursor within wrapped input rows using the same byte-offset view that painting uses.
;; tags: tui input cursor wrapping
(fn M.cursor-display-pos [rows cursor]
  "Return (row-index-0, col) for cursor in wrapped input rows."
  (var row-idx 0)
  (var col 0)
  (each [i row (ipairs rows)]
    (when (and (>= cursor row.start) (<= cursor row.end))
      (set row-idx (- i 1))
      (set col (math.min (length row.text) (- cursor row.start)))))
  (values row-idx col))

;; @doc fen.extensions.tui.input.input-rows
;; kind: function
;; signature: (input-rows) -> number
;; summary: Return the current input region height, capped for multiline editing and terminal layout stability.
;; tags: tui input layout
(fn M.input-rows []
  "Number of rows the input area occupies, capped at INPUT-ROWS-MAX."
  (let [w (math.max 1 (or state.tb-cols 1))]
    (math.min INPUT-ROWS-MAX
              (math.max 1 (length (M.input-display-rows state.input-buf
                                                         w
                                                         state.input-cursor))))))

;; @doc fen.extensions.tui.input.paint-input
;; kind: function
;; signature: (paint-input layout) -> nil
;; summary: Paint the visible wrapped input rows and place or hide the terminal cursor within the input region.
;; tags: tui input paint cursor
(fn M.paint-input [{: w : input-y0 : input-y1 : input-h}]
  ;; Prompt on the first visual row; subsequent visual rows (soft wraps and
  ;; explicit newlines) get blank padding aligned under the prompt.
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
        (draw.put-clipped 0 y (if first? IC.prompt IC.dim) IC.normal prefix prefix-w)
        (draw.put-clipped prefix-w y IC.normal IC.normal (or (?. row :text) "") text-w)))
    (let [screen-row (- cur-row first-visible)
          row (. rows (+ cur-row 1))
          prefix-w (if (and row row.first?) prompt-w cont-w)
          cur-x (+ prefix-w cur-col)
          cur-y (+ input-y0 screen-row)]
      (if (and (>= screen-row 0) (< screen-row input-h) (< cur-x w))
          (tb.set_cursor cur-x cur-y)
          (tb.hide_cursor)))))

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

(fn insert-text [text]
  (let [buf state.input-buf
        c state.input-cursor
        before (string.sub buf 1 c)
        after (string.sub buf (+ c 1))]
    (set state.input-buf (.. before text after))
    (set state.input-cursor (+ c (length text)))))

(local LARGE-PASTE-LINES 10)
(local LARGE-PASTE-CHARS 1000)

(fn normalize-paste [text]
  "Normalize pasted text: CRLF/CR to LF and tabs to four spaces."
  (let [s (text:gsub "\r\n" "\n")
        s (s:gsub "\r" "\n")]
    (s:gsub "\t" "    ")))

(fn filter-paste [text]
  (let [out []]
    (for [i 1 (length text)]
      (let [ch (string.sub text i i)
            b (string.byte ch)]
        (when (or (= ch "\n") (>= b 32))
          (table.insert out ch))))
    (table.concat out)))

(fn paste-line-count [text]
  (var n 1)
  (for [i 1 (length text)]
    (when (= (string.sub text i i) "\n")
      (set n (+ n 1))))
  n)

(fn marker-pattern [marker]
  (marker:gsub "([^%w])" "%%%1"))

(fn expand-paste-markers [text]
  (var out text)
  (each [id p (pairs (or state.pastes {}))]
    (when (and p.marker p.text)
      (set out (out:gsub (marker-pattern p.marker) (fn [] p.text)))))
  out)

(fn handle-paste [text]
  (let [clean (filter-paste (normalize-paste (or text "")))
        lines (paste-line-count clean)
        chars (length clean)]
    (when (> chars 0)
      (if (or (> lines LARGE-PASTE-LINES) (> chars LARGE-PASTE-CHARS))
          (do
            (set state.paste-counter (+ (or state.paste-counter 0) 1))
            (let [id state.paste-counter
                  marker (if (> lines LARGE-PASTE-LINES)
                             (.. "[paste #" id " +" lines " lines]")
                             (.. "[paste #" id " " chars " chars]"))]
              (tset state.pastes id {:marker marker :text clean})
              (insert-text marker)))
          (insert-text clean)))))

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

;; ---------- slash command completion ----------

(fn common-prefix [items]
  (if (= (length items) 0) ""
      (let [prefix (. items 1)]
        (var n (length prefix))
        (each [i item (ipairs items)]
          (when (> i 1)
            (while (and (> n 0)
                        (not= (string.sub prefix 1 n)
                              (string.sub item 1 n)))
              (set n (- n 1)))))
        (string.sub prefix 1 n))))

(fn command-completion-context []
  "Return (prefix, command-end) when the cursor is in the first slash-command token."
  (let [buf state.input-buf
        c state.input-cursor
        before (string.sub buf 1 c)
        prefix (string.match before "^/([^%s]*)$")]
    (when prefix
      (let [after (string.sub buf (+ c 1))
            rel-space (string.find after "%s")
            command-end (if rel-space (+ c (- rel-space 1)) (length buf))]
        (values prefix command-end)))))

(fn replace-command-token [name command-end add-space?]
  (let [buf state.input-buf
        after (string.sub buf (+ command-end 1))
        space? (and add-space? (not (string.match after "^%s")))
        replacement (.. "/" name (if space? " " ""))]
    (set state.input-buf (.. replacement after))
    (set state.input-cursor (length replacement))))

(fn completion-match-names [prefix]
  (let [matches []]
    (each [_ cmd (ipairs (command-registry.list))]
      (let [name (tostring cmd.name)]
        (when (= (string.sub name 1 (length prefix)) prefix)
          (table.insert matches name))))
    (table.sort matches)
    matches))

(fn emit-completion-hint [matches]
  (when (and state.api (> (length matches) 0))
    (let [shown []
          limit (math.min 12 (length matches))]
      (for [i 1 limit]
        (table.insert shown (.. "/" (. matches i))))
      (when (> (length matches) limit)
        (table.insert shown (.. "+" (- (length matches) limit) " more")))
      (state.api.emit {:type :info
                       :text (.. "commands: " (table.concat shown " "))}))))

(fn exact-match? [matches prefix]
  (var found? false)
  (each [_ name (ipairs matches)]
    (when (= name prefix)
      (set found? true)))
  found?)

(fn complete-command []
  "Complete slash-command names when the cursor is in the command token."
  (let [(prefix command-end) (command-completion-context)]
    (if (= prefix nil)
        (insert-text "\t")
        (let [matches (completion-match-names prefix)]
          (if (= (length matches) 0)
              false
              (= (length matches) 1)
              (do (replace-command-token (. matches 1) command-end true)
                  true)
              (exact-match? matches prefix)
              (do (replace-command-token prefix command-end true)
                  true)
              (let [common (common-prefix matches)]
                (if (> (length common) (length prefix))
                    (do (replace-command-token common command-end false)
                        true)
                    (do (emit-completion-hint matches)
                        true))))))))

;; ---------- history navigation ----------

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

;; Up/Down: navigate by visual wrapped rows (which paint owns), falling
;; back to history when at the visual top/bottom of the input.

(fn cursor-up-or-history []
  (let [rows (M.input-display-rows state.input-buf
                                       (math.max 1 (or state.tb-cols 1))
                                       state.input-cursor)
        (cur-row col) (M.cursor-display-pos rows state.input-cursor)]
    (if (= cur-row 0)
        (history-prev)
        (let [target (. rows cur-row) ;; cur-row is 0-based; table is 1-based.
              target-col (math.min col (length target.text))]
          (set state.input-cursor (+ target.start target-col))))))

(fn cursor-down-or-history []
  (let [rows (M.input-display-rows state.input-buf
                                       (math.max 1 (or state.tb-cols 1))
                                       state.input-cursor)
        (cur-row col) (M.cursor-display-pos rows state.input-cursor)
        last-row (- (length rows) 1)]
    (if (>= cur-row last-row)
        (history-next)
        (let [target (. rows (+ cur-row 2))
              target-col (math.min col (length target.text))]
          (set state.input-cursor (+ target.start target-col))))))

(fn submit! [on-submit]
  (let [line (expand-paste-markers state.input-buf)]
    (set state.input-buf "")
    (set state.input-cursor 0)
    (set state.history-pos 0)
    (set state.history-draft "")
    (when (not= line "")
      (table.insert state.history line)
      ;; Promote the user's submission onto the bus. The TUI's :*
      ;; subscriber appends it to the transcript; other extensions
      ;; (loggers, command interceptors) can observe the same way.
      (state.api.emit {:type :user :text line})
      ;; on-submit may call agent.step which emits more events; those
      ;; will redraw on append. We catch failures so a buggy step doesn't
      ;; kill the loop.
      (let [(ok? err) (pcall on-submit line)]
        (when (not ok?)
          (state.api.emit {:type :error
                            :error (.. "submit: " (tostring err))}))))))

(fn scroll-by [delta]
  (set state.last-user-jump-index nil)
  (set state.scroll-offset
       (math.max 0 (math.min (transcript.max-scroll (M.input-rows)) (+ state.scroll-offset delta))))
  (when (= state.scroll-offset 0)
    (set state.new-content-below? false)))

;; ---------- key dispatch ----------

(local KEY-CTRL-G 0x07)
(local KEY-CTRL-O 0x0f) ;; termbox2 defines this but our Lua shim doesn't export it yet.
(local KEY-CTRL-T 0x14)
(local KEY-CTRL-Y 0x19)
(local KEY-PASTE-BEGIN (or tb.KEY_PASTE_BEGIN -1000000))
(local KEY-PASTE-END (or tb.KEY_PASTE_END -1000001))

(fn paste-event-text [ev]
  (let [k ev.key
        ch ev.ch]
    (if (or (= k tb.KEY_ENTER) (= k tb.KEY_CTRL_J)) "\n"
        (= k tb.KEY_TAB) "\t"
        (and (not= ch 0) ev.utf8) ev.utf8
        (and (not= ch 0) (>= ch 32)) (string.char (band ch 0xFF))
        "")))

(fn toggle-tool-results []
  (set state.expand-tool-results? (not state.expand-tool-results?))
  (state.api.emit {:type :redraw}))

(fn toggle-thinking-blocks []
  (set state.hide-thinking-block? (not state.hide-thinking-block?))
  (state.api.emit {:type :redraw}))

;; @doc fen.extensions.tui.input.handle-key
;; kind: function
;; signature: (handle-key ev on-submit on-cancel is-busy?) -> boolean|nil
;; summary: Dispatch a termbox key event into buffer edits, history movement, submission, cancellation, or quit handling.
;; tags: tui input keyboard events
(fn M.handle-key [ev on-submit on-cancel is-busy?]
  "Mutates state in response to a single key event. Returns true if the
   event requests session quit. on-cancel and is-busy? are optional —
   when present, ctrl-c during a busy turn requests cancellation instead
   of falling into the normal two-press quit."
  (M.ensure-defaults!)
  ;; If KEY_ESC fired on the previous event, treat this event as
  ;; Esc+<key> (Alt+<key>) by synthesizing MOD_ALT. The run loop's
  ;; idle path fires :dismiss when a tick passes without a follow-up.
  (let [alt-injected? (and state.alt-pending? (not= ev.key tb.KEY_ESC))]
    (when alt-injected?
      (set state.alt-pending? false)
      (set ev.mod (bor (or ev.mod 0) tb.MOD_ALT))))
  (let [k ev.key
        m (or ev.mod 0)
        ch ev.ch
        busy? (and is-busy? (is-busy?))]
    ;; Reset pending-quit on any non-Ctrl-C key.
    (when (and state.pending-quit? (not= k tb.KEY_CTRL_C))
      (set state.pending-quit? false))
    (if
      ;; ----- bracketed paste -----
      (= k KEY-PASTE-BEGIN)
      (do (set state.paste-active? true)
          (set state.paste-buffer "")
          false)

      (= k KEY-PASTE-END)
      (do (handle-paste state.paste-buffer)
          (set state.paste-active? false)
          (set state.paste-buffer "")
          false)

      state.paste-active?
      (do (set state.paste-buffer (.. (or state.paste-buffer "") (paste-event-text ev)))
          false)

      ;; ----- submit / newline -----
      (= k tb.KEY_ENTER)
      (do (submit! on-submit) false)

      (= k tb.KEY_CTRL_J)
      (do (insert-text "\n") false)

      ;; ----- transcript navigation / view toggles -----
      (= k KEY-CTRL-G)
      (do (transcript.jump-to-user-message! (M.input-rows)) false)

      (= k KEY-CTRL-Y)
      (do (set state.scroll-offset 0)
          (set state.new-content-below? false)
          (set state.last-user-jump-index nil)
          false)

      ;; Match pi-mono's app.tools.expand default keybinding.
      (= k KEY-CTRL-O)
      (do (toggle-tool-results) false)

      ;; Match pi-mono's app.thinking.toggle default keybinding.
      (= k KEY-CTRL-T)
      (do (toggle-thinking-blocks) false)

      ;; ----- panel dismiss -----
      ;; Esc arrives in INPUT_ESC mode as KEY_ESC. Defer the :dismiss
      ;; emit to the run loop's idle path so an Esc + key combo within
      ;; one tick is treated as Alt+key (MOD_ALT synthesized at the top
      ;; of this fn). Bare Esc surfaces as :dismiss on the next idle
      ;; tick (~30 ms), which the mem panel and any future togglable
      ;; panel subscribe to.
      (= k tb.KEY_ESC)
      (do (set state.alt-pending? true) false)

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
      ;; Some terminals/termbox paths surface Tab as KEY_TAB; others report
      ;; it as raw Ctrl-I. termbox2's production extractor emits Ctrl-I as
      ;; key=9,ch=0,mod=CTRL; older/stale Lua shims may not export KEY_TAB, so
      ;; accept the numeric code directly too. Keep key=0,ch=9 for synthetic
      ;; tests or alternate shims that expose it as character input.
      (or (= k tb.KEY_TAB) (= k 9) (and (= k 0) (= ch 9)))
      (do (complete-command) false)

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

;; @doc fen.extensions.tui.input.handle-mouse
;; kind: function
;; signature: (handle-mouse ev) -> nil
;; summary: Interpret mouse wheel and click events for transcript scrolling, panel focus, and redraw invalidation.
;; tags: tui input mouse scroll
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

;; @doc fen.extensions.tui.input.handle-event
;; kind: function
;; signature: (handle-event ev on-submit on-cancel is-busy?) -> boolean|nil
;; summary: Route termbox keyboard, mouse, resize, paste, and Alt-synthesized events through the TUI input layer.
;; tags: tui input events termbox
(fn M.handle-event [ev on-submit on-cancel is-busy?]
  (if (= ev.type tb.EVENT_RESIZE)
      (do (set state.tb-cols (math.max 1 ev.w))
          (set state.tb-rows (math.max 1 ev.h))
          (set state.last-user-jump-index nil)
          (set state.scroll-offset (math.min state.scroll-offset (transcript.max-scroll (M.input-rows))))
          (when (= state.scroll-offset 0)
            (set state.new-content-below? false))
          (redraw.invalidate-full!)
          false)
      (= ev.type tb.EVENT_KEY)
      (let [quit? (M.handle-key ev on-submit on-cancel is-busy?)]
        (when (not quit?)
          (redraw.invalidate!))
        quit?)
      (= ev.type tb.EVENT_MOUSE)
      (let [quit? (M.handle-mouse ev)]
        (when (not quit?)
          (redraw.invalidate!))
        quit?)
      false))

M
