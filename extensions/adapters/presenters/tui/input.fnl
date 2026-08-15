;; TUI input handling: buffer mutation, history navigation, key dispatch.
;; Hot-reload: manual-reload! mutates exports in place so callers keep the module-table reference.

(local state (require :fen.extensions.tui.state))
(local tb (require :termbox2))
(local redraw (require :fen.extensions.tui.redraw))
(local draw (require :fen.extensions.tui.draw))
(local transcript (require :fen.extensions.tui.panels.transcript))
(local completion (require :fen.extensions.tui.completion))
(local selection (require :fen.extensions.tui.selection))
(local workspaces (require :fen.extensions.tui.workspaces))
(local side-chat (require :fen.extensions.tui.side_chat))
(local clipboard (require :fen.extensions.tui.clipboard))

(local M {})

(local INPUT-ROWS-MAX 5)

(local IC
  {:dim    (bor tb.WHITE tb.DIM)
   :prompt (bor tb.CYAN tb.BOLD)
   :normal tb.DEFAULT})

(fn M.input-prompt []
  "Return the active tab's editor label without changing main-session chrome."
  (let [mode (workspaces.input-mode (workspaces.active))]
    (if (= mode :steer) "Steer> "
        (= mode :side) "btw> "
        (= mode :readonly) "Read-only> "
        "> ")))

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
  (when (= state.last-user-jump-index nil) (set state.last-user-jump-index nil))
  (selection.ensure-defaults!)
  (completion.ensure-defaults!))

(fn M.input-display-rows [buf width cursor ?prompt-width]
  "Return wrapped input display rows.

   Rows carry byte offsets into `buf` so cursor positioning can use the same
   wrapped view that painting uses. The first visual row gets the prompt; every
   subsequent visual row (soft wrap or explicit newline) gets a continuation
   marker. Wrapping is byte-based, matching the rest of this TUI's Phase-1
   rendering assumptions."
  (let [prompt-w (or ?prompt-width 2)
        cont-w prompt-w
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

(fn M.cursor-display-pos [rows cursor]
  "Return (row-index-0, col) for cursor in wrapped input rows."
  (var row-idx 0)
  (var col 0)
  (each [i row (ipairs rows)]
    (when (and (>= cursor row.start) (<= cursor row.end))
      (set row-idx (- i 1))
      (set col (math.min (length row.text) (- cursor row.start)))))
  (values row-idx col))

(fn M.input-rows []
  "Number of rows the input area occupies, capped at INPUT-ROWS-MAX."
  (let [w (math.max 1 (or state.tb-cols 1))
        prompt-w (length (M.input-prompt))]
    (math.min INPUT-ROWS-MAX
              (math.max 1 (length (M.input-display-rows state.input-buf
                                                         w
                                                         state.input-cursor
                                                         prompt-w))))))

;; @doc fen.extensions.tui.input.paint-input
;; kind: function
;; signature: (paint-input layout) -> nil
;; summary: Paint the visible wrapped input rows and place or hide the terminal cursor within the input region.
;; tags: tui input paint cursor
(fn M.paint-input [{: w : input-y0 : input-y1 : input-h}]
  (let [prompt (M.input-prompt)
        prompt-w (length prompt)
        cont (string.rep " " prompt-w)
        cont-w prompt-w
        rows (M.input-display-rows state.input-buf w state.input-cursor prompt-w)
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
      (if (and (workspaces.accepts-input?)
               (>= screen-row 0) (< screen-row input-h) (< cur-x w))
          (tb.set_cursor cur-x cur-y)
          (tb.hide_cursor)))))

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
        start (or (if (> cursor 0)
                      (let [(s _) (string.find (string.sub buf 1 cursor)
                                               "\n[^\n]*$")]
                        (if s s nil))
                      nil)
                  0)
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

;; refresh-completion! runs from the key-dispatch tail so the live menu tracks the buffer without every editing branch knowing about it.

(fn M.refresh-completion! []
  "Recompute main-session completion, or close it outside main input mode."
  (if (= (workspaces.input-mode (workspaces.active)) :main)
      (completion.refresh! (or state.presenter-ctx {}))
      (completion.close!)))

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

(fn labels-of [items]
  (let [out []]
    (each [_ it (ipairs items)]
      (table.insert out (or it.label "")))
    out))

(fn exact-label? [items label]
  (var found? false)
  (each [_ it (ipairs items)]
    (when (= it.label label) (set found? true)))
  found?)

(fn complete-command []
  "Tab handler. Opens/advances the live completion menu when the cursor is
   in a slash context; otherwise inserts a literal tab.

   With the menu open: commit when a single candidate remains, commit an
   exact command-name match, extend to the longest common command prefix
   when it grows the typed text, and otherwise cycle the selection so
   repeated Tab walks the candidates."
  (M.refresh-completion!)
  (let [comp-ctx (completion.context state.input-buf state.input-cursor)]
    (if (= comp-ctx nil)
        (do (insert-text "\t") false)
        (not (completion.active?))
        ;; Context exists but produced no candidates (unknown prefix, or arg region with no completer).
        false
        (let [items state.completion.items]
          (if (= (length items) 1)
              (completion.commit!)
              (and (= comp-ctx.kind :command)
                   (exact-label? items comp-ctx.prefix)
                   (<= (length (common-prefix (labels-of items)))
                       (length comp-ctx.prefix)))
              (do (set state.completion.cursor
                       (do (var idx 1)
                           (each [i it (ipairs items)]
                             (when (= it.label comp-ctx.prefix) (set idx i)))
                           idx))
                  (completion.commit!))
              (= comp-ctx.kind :command)
              (let [common (common-prefix (labels-of items))]
                (if (> (length common) (length comp-ctx.prefix))
                    (do (set state.input-buf
                             (.. "/" common
                                 (string.sub state.input-buf (+ comp-ctx.token-end 1))))
                        (set state.input-cursor (+ 1 (length common)))
                        (M.refresh-completion!)
                        true)
                    (do (completion.next!) true)))
              (do (completion.next!) true))))))

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

(fn cursor-up-or-history []
  (let [rows (M.input-display-rows state.input-buf
                                    (math.max 1 (or state.tb-cols 1))
                                    state.input-cursor
                                    (length (M.input-prompt)))
        (cur-row col) (M.cursor-display-pos rows state.input-cursor)]
    (if (= cur-row 0)
        (history-prev)
        (let [target (. rows cur-row) ;; cur-row is 0-based; table is 1-based.
              target-col (math.min col (length target.text))]
          (set state.input-cursor (+ target.start target-col))))))

(fn cursor-down-or-history []
  (let [rows (M.input-display-rows state.input-buf
                                    (math.max 1 (or state.tb-cols 1))
                                    state.input-cursor
                                    (length (M.input-prompt)))
        (cur-row col) (M.cursor-display-pos rows state.input-cursor)
        last-row (- (length rows) 1)]
    (if (>= cur-row last-row)
        (history-next)
        (let [target (. rows (+ cur-row 2))
              target-col (math.min col (length target.text))]
          (set state.input-cursor (+ target.start target-col))))))

(fn clear-submitted-input! [line]
  (set state.input-buf "")
  (set state.input-cursor 0)
  (set state.history-pos 0)
  (set state.history-draft "")
  (table.insert state.history line))

(fn submit-main! [line on-submit]
  (clear-submitted-input! line)
  ;; Steering drafts deliberately bypass this path so they cannot become a parent-session prompt.
  (state.api.emit {:type :user :text line})
  ;; pcall so a buggy on-submit (agent.step) cannot kill the presenter loop.
  (let [(ok? err) (pcall on-submit line)]
    (when (not ok?)
      (state.api.emit {:type :error
                       :error (.. "submit: " (tostring err))}))))

(fn submit-command! [line on-submit]
  "Dispatch a workspace-owned command without emitting it into main history."
  (clear-submitted-input! line)
  (let [(ok? err) (pcall on-submit line)]
    (when (not ok?)
      (workspaces.append-active!
        {:type :error :error (.. "submit: " (tostring err))}))))

(fn submit! [on-submit]
  (completion.close!)
  (let [line (expand-paste-markers state.input-buf)]
    (when (not= line "")
      (workspaces.submit!
        line
        {:main (fn [text] (submit-main! text on-submit))
         :command (fn [text] (submit-command! text on-submit))
         :side (fn [ws text]
                 (let [result (side-chat.submit! ws text)]
                   (if result.ok
                       (clear-submitted-input! text)
                       (workspaces.append-active!
                         {:type :error :error (tostring result.error)}))))
         :steer (fn [text]
                  (let [(ok? err) (workspaces.submit-steering! text)]
                    (if ok?
                        (do
                          (when (= (string.sub text 1 1) "/")
                            (workspaces.append-active!
                              {:type :info
                               :text "slash command sent literally as steering note"}))
                          (clear-submitted-input! text)
                          (workspaces.sync-subagents!))
                        (workspaces.append-active!
                          {:type :error :error (tostring err)}))))}))))

(fn scroll-by [delta]
  ;; Scrolling invalidates selection screen-cell anchors, so drop the selection.
  (selection.clear!)
  (set state.last-user-jump-index nil)
  (let [candidate (+ state.scroll-offset delta)]
    (set state.scroll-offset
         (if (> delta 0)
             (transcript.clamp-scroll-offset candidate (M.input-rows))
             (math.max 0 candidate))))
  (when (= state.scroll-offset 0)
    (set state.new-content-below? false)))

(local KEY-CTRL-G 0x07)
(local KEY-CTRL-L (or tb.KEY_CTRL_L 0x0c))
(local KEY-CTRL-O 0x0f) ;; termbox2 defines this but our Lua shim doesn't export it yet.
(local KEY-CTRL-T 0x14)
(local KEY-CTRL-Y 0x19)
(local KEY-CTRL-Z (or tb.KEY_CTRL_Z 0x1a))
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

(fn read-only-key? [k _m]
  "Only transcript/tab navigation and safe terminal controls work when the
   focused tab has no active main or steering editor."
  (or (= k tb.KEY_ESC)
      (= k tb.KEY_CTRL_C) (= k tb.KEY_CTRL_D)
      (= k KEY-CTRL-G) (= k KEY-CTRL-Y)
      (= k KEY-CTRL-L) (= k KEY-CTRL-Z)
      (= k tb.KEY_PGUP) (= k tb.KEY_PGDN)))

(fn M.open-workspace-switcher! []
  "Open the existing modal selector so popup focus remains single-owner."
  (let [api state.api
        tabs (workspaces.list)]
    (when (and (> (length tabs) 1) api api.ui
               (= (type api.ui.select) :function))
      (completion.close!)
      (let [picked (api.ui.select {:label "tabs"
                                   :choices (workspaces.switcher-choices)})]
        (when (and picked (not= picked.value nil))
          (workspaces.activate! picked.value))))))

(fn toggle-tool-results []
  (set state.expand-tool-results? (not state.expand-tool-results?))
  (state.api.emit {:type :redraw}))

(fn toggle-thinking-blocks []
  (set state.hide-thinking-block? (not state.hide-thinking-block?))
  (state.api.emit {:type :redraw}))

(fn M.handle-key [ev on-submit on-cancel is-busy?]
  "Mutates state in response to a single key event. Returns true if the
   event requests session quit. on-cancel and is-busy? are optional —
   when present, ctrl-c during a busy turn requests cancellation instead
   of falling into the normal two-press quit."
  (M.ensure-defaults!)
  ;; A prior bare KEY_ESC arms alt-pending?; this event becomes Alt+<key> via synthesized MOD_ALT.
  (let [alt-injected? (and state.alt-pending? (not= ev.key tb.KEY_ESC))]
    (when alt-injected?
      (set state.alt-pending? false)
      (set ev.mod (bor (or ev.mod 0) tb.MOD_ALT))))
  (let [k ev.key
        m (or ev.mod 0)
        ch ev.ch
        busy? (and is-busy? (is-busy?))]
    (when (and state.pending-quit? (not= k tb.KEY_CTRL_C))
      (set state.pending-quit? false))
    (let [quit?
    (if
      ;; Workspace movement must precede the read-only boundary: Alt-arrow is a tab shortcut.
      (and (= (band m tb.MOD_ALT) tb.MOD_ALT) (= k tb.KEY_ARROW_RIGHT))
      (do (workspaces.next! 1) false)

      (and (= (band m tb.MOD_ALT) tb.MOD_ALT) (= k tb.KEY_ARROW_LEFT))
      (do (workspaces.next! -1) false)

      (and (= (band m tb.MOD_ALT) tb.MOD_ALT)
           (or (= ch 0x74) (= k KEY-CTRL-T)))
      (do (M.open-workspace-switcher!) false)

      ;; Ctrl-W close intentionally outranks delete-word-back on closable tabs so closing works with mouse capture off.
      (and (= k tb.KEY_CTRL_W)
           (workspaces.closable? (workspaces.active)))
      (do (workspaces.close! (. (workspaces.active) :id)) false)

      ;; Reject editor/paste/submit keys only when this tab has no input mode.
      (and (not (workspaces.accepts-input?))
           (not (read-only-key? k m)))
      false

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

      ;; Open completion menu captures navigation/commit keys; Tab and printable input fall through.
      (and (completion.active?) (= k tb.KEY_ESC))
      ;; Preserve Esc/Alt disambiguation: bare Esc closes via idle :dismiss; Esc+key still synthesizes MOD_ALT.
      (do (set state.alt-pending? true) false)

      (and (completion.active?) (= k tb.KEY_ENTER))
      (if (completion.selected-exact-command?)
          ;; Typed command is already exact: Enter runs the line instead of re-committing it with a space.
          (do (submit! on-submit) false)
          ;; Arg commits dismiss the snapshot so the next Enter submits; command commits refresh for arg choices.
          (do (completion.commit! (= state.completion.kind :arg)) false))

      (and (completion.active?)
           (or (= k tb.KEY_ARROW_DOWN)
               (and (= k tb.KEY_CTRL_N) (not= (band m tb.MOD_ALT) tb.MOD_ALT))))
      (do (completion.next!) false)

      (and (completion.active?)
           (or (= k tb.KEY_ARROW_UP)
               (and (= k tb.KEY_CTRL_P) (not= (band m tb.MOD_ALT) tb.MOD_ALT))))
      (do (completion.prev!) false)

      (= k tb.KEY_ENTER)
      (if (workspaces.accepts-input?)
          (do (submit! on-submit) false)
          false)

      (= k tb.KEY_CTRL_J)
      (do (insert-text "\n") false)

      (= k KEY-CTRL-G)
      (do (transcript.jump-to-user-message! (M.input-rows)) false)

      (= k KEY-CTRL-Y)
      (do (set state.scroll-offset 0)
          (set state.new-content-below? false)
          (set state.last-user-jump-index nil)
          false)

      (= k KEY-CTRL-O)
      (do (toggle-tool-results) false)

      (= k KEY-CTRL-T)
      (do (toggle-thinking-blocks) false)

      ;; Ctrl-L: hard refresh to recover from external terminal corruption.
      (= k KEY-CTRL-L)
      (do (state.api.emit {:type :hard-refresh}) false)

      ;; Ctrl-Z: raw mode swallows SIGTSTP, so suspend arrives as a key; :suspend blocks until resume.
      (= k KEY-CTRL-Z)
      (do (state.api.emit {:type :suspend}) false)

      ;; Defer :dismiss to the run loop's idle tick so Esc+key within one tick becomes Alt+key.
      (= k tb.KEY_ESC)
      (do (set state.alt-pending? true) false)

      (= k tb.KEY_CTRL_D)
      true

      (= k tb.KEY_CTRL_C)
      (if (workspaces.cancel-active!)
          ;; Workspace-owned turns cancel via their kind policy, never the main-session quit ladder.
          false
          (and busy? state.cancel-pressed?)
          true
          busy?
          ;; First busy press queues cancellation; the agent coroutine bails at its next yield and emits :cancelled.
          (do (when on-cancel (on-cancel))
              (set state.cancel-pressed? true)
              (set state.status-info.cancelling? true)
              false)
          (and (workspaces.allows? :submit)
               (not= state.input-buf "") (not state.pending-quit?))
          (do (set state.input-buf "")
              (set state.input-cursor 0)
              (set state.history-pos 0)
              false)
          state.pending-quit?
          true
          (do (set state.pending-quit? true) false))

      ;; Tab may arrive as KEY_TAB, raw Ctrl-I (key=9), or key=0,ch=9 from synthetic tests/alternate shims.
      (or (= k tb.KEY_TAB) (= k 9) (and (= k 0) (= ch 9)))
      (do (if (= (workspaces.input-mode (workspaces.active)) :main)
              (complete-command)
              (insert-text "\t"))
          false)

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

      ;; Alt-P / Alt-N: history navigation even where arrow keys arrive without modifiers.
      (and (= ch 0x70) (= (band m tb.MOD_ALT) tb.MOD_ALT))
      (do (history-prev) false)

      (and (= ch 0x6e) (= (band m tb.MOD_ALT) tb.MOD_ALT))
      (do (history-next) false)

      ;; Some terminals surface Alt-P / Alt-N as KEY_CTRL_P/_N + MOD_ALT.
      (and (= k tb.KEY_CTRL_P) (= (band m tb.MOD_ALT) tb.MOD_ALT))
      (do (history-prev) false)

      (and (= k tb.KEY_CTRL_N) (= (band m tb.MOD_ALT) tb.MOD_ALT))
      (do (history-next) false)

      (= k tb.KEY_PGUP)
      (do (scroll-by (math.max 1 (math.floor (/ state.tb-rows 2)))) false)

      (= k tb.KEY_PGDN)
      (do (scroll-by (- (math.max 1 (math.floor (/ state.tb-rows 2))))) false)

      (and (not= ch 0) (or (= k 0) (= k tb.KEY_SPACE)))
      (do (insert-text (or ev.utf8 (string.char (band ch 0xFF)))) false)

      false)]
      ;; Snapshot-guarded menu sync after every key; skipped on quit so state is untouched on the way out.
      (when (not quit?)
        (M.refresh-completion!))
      quit?)))

(local MOUSE-WHEEL-LINES 3)

(fn M.copy-selection! []
  "Extract the currently selected transcript text and copy it via OSC 52.
   Records a transient copy-status on state so the status line can report
   the outcome. No-op (and no status) when the selection is empty."
  (let [text (selection.selected-text)]
    (when (not= text "")
      (let [result (clipboard.copy text)]
        (set state.copy-status {:ok? result.ok?
                                :bytes result.bytes
                                :reason result.reason
                                :at-seconds (os.time)})))))

(fn clicked-tab [x y]
  (var action nil)
  (let [lay state.paint-layout]
    (when (and lay (>= x 0) (< x (or lay.w 0)))
      (each [_ slot (ipairs (or lay.below-status-panels []))]
        (when (and (= slot.name :tabs) (>= y slot.y0) (<= y slot.y1))
          ;; Resolve at call time so input does not capture reloadable panel behavior across /reload.
          (let [(ok? tabs) (pcall require :fen.extensions.tui.panels.tabs)]
            (when ok?
              (if (= (type tabs.action-at) :function)
                  (set action (tabs.action-at x lay.w))
                  (= (type tabs.tab-at) :function)
                  (let [id (tabs.tab-at x lay.w)]
                    (when id
                      (set action {:workspace-id id :action :activate}))))))))))
  action)

(fn M.handle-mouse [ev]
  "Wheel up/down scrolls the transcript by MOUSE-WHEEL-LINES per notch.
   Clicking a visible workspace tab activates it. Left-button dragging in the
   transcript selects text, with OSC 52 copy on release. Under tmux with
   `set -g mouse on`, tmux forwards these SGR mouse events to the foreground
   pane while we have INPUT_MOUSE enabled."
  (let [k ev.key
        x (or ev.x 0)
        y (or ev.y 0)
        motion? (= (band (or ev.mod 0) tb.MOD_MOTION) tb.MOD_MOTION)
        tab-action (and (= k tb.KEY_MOUSE_LEFT) (not motion?) (clicked-tab x y))]
    (if tab-action
        (do (selection.clear!)
            (if (= tab-action.action :close)
                (workspaces.close! tab-action.workspace-id)
                (workspaces.activate! tab-action.workspace-id))
            false)
        (= k tb.KEY_MOUSE_WHEEL_UP)
        (do (scroll-by MOUSE-WHEEL-LINES) false)
        (= k tb.KEY_MOUSE_WHEEL_DOWN)
        (do (scroll-by (- MOUSE-WHEEL-LINES)) false)
        ;; termbox reports drag as KEY_MOUSE_LEFT | MOD_MOTION.
        (and (= k tb.KEY_MOUSE_LEFT) motion?)
        (do (if (selection.active?)
                (selection.update-clamped! x y)
                (selection.start-if-selectable! x y))
            false)
        ;; Left press anchors a selection only on painted transcript text; status/input/panel clicks do not.
        (= k tb.KEY_MOUSE_LEFT)
        (do (selection.clear!)
            (selection.start-if-selectable! x y)
            false)
        ;; Release: copy only a real drag (span beyond the anchor cell); a plain click clears instead.
        (= k tb.KEY_MOUSE_RELEASE)
        (do (let [updated? (selection.update-clamped! x y)]
              (if updated?
                  (do (selection.finish!)
                      (if (and (selection.has-span?)
                               (not= (selection.selected-text) ""))
                          (M.copy-selection!)
                          (selection.clear!)))
                  (selection.clear!)))
            false)
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
