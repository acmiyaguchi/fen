;; Helpers for fast in-process TUI tests.
;; These deliberately avoid the real terminal by installing a termbox2 stub
;; before tests require TUI modules.

(local M {})

(fn utf8-step [s i]
  (let [b (string.byte s i)]
    (if (= b nil) 1
        (< b 128) 1
        (< b 224) 2
        (< b 240) 3
        4)))

(fn cell-text [ch]
  (if (= (type ch) :string) ch
      (and (= (type ch) :number) (>= ch 0) (< ch 128)) (string.char ch)
      " "))

(fn put-utf8-text! [grid x y text]
  (let [row (. grid (+ y 1))]
    (when row
      (var col (+ x 1))
      (var i 1)
      (let [s (tostring (or text ""))]
        (while (and (<= i (length s)) (<= col (length row)))
          (let [step (utf8-step s i)
                j (+ i step -1)]
            (when (<= j (length s))
              (tset row col (string.sub s i j))
              (set col (+ col 1)))
            (set i (+ i step))))))))

(fn clone-grid [grid]
  (let [out []]
    (each [y row (ipairs (or grid []))]
      (tset out y [])
      (each [x cell (ipairs row)]
        (tset (. out y) x cell)))
    out))

(fn trailing-trim [s]
  (let [(out _) (string.gsub (or s "") "%s+$" "")]
    out))

(fn grid-lines [grid trim?]
  (let [out []]
    (each [_ row (ipairs (or grid []))]
      (let [line (table.concat row "")]
        (table.insert out (if trim? (trailing-trim line) line))))
    out))

(fn reset-screen! [stub]
  (when stub.capture?
    (let [w (math.max 1 (or stub.width-value 80))
          h (math.max 1 (or stub.height-value 24))
          grid []]
      (for [y 1 h]
        (let [row []]
          (for [x 1 w]
            (tset row x " "))
          (tset grid y row)))
      (set stub.screen grid))))

(fn ensure-screen! [stub]
  (when (and stub.capture? (= stub.screen nil))
    (reset-screen! stub)))

;; @doc fen.testing.tui.install-termbox-stub!
;; kind: function
;; signature: (install-termbox-stub! ?opts) -> table
;; summary: Install a safe termbox2 test double, optionally with text screen capture for whole-frame assertions.
;; tags: testing tui termbox screen capture
(fn M.install-termbox-stub! [?opts]
  "Install a safe termbox2 test double in package.loaded and return it.
   Pass {:capture? true :cols N :rows N} to record printed text into an
   in-memory screen for whole-frame assertions. The default remains a small
   no-op stub for existing state/logic tests."
  (let [opts (or ?opts {})
        stub {:capture? (= opts.capture? true)}
        consts {:DEFAULT 0 :BLACK 0 :CYAN 6 :GREEN 2 :RED 1 :YELLOW 3
                :WHITE 7 :BLUE 4 :MAGENTA 5
                :BOLD 1 :DIM 2 :REVERSE 4 :UNDERLINE 8 :ITALIC 16
                :STRIKEOUT 32
                :KEY_ENTER 13 :KEY_CTRL_C 3 :KEY_CTRL_D 4
                :KEY_CTRL_J 10 :KEY_CTRL_O 15 :KEY_CTRL_T 20
                :KEY_TAB 9 :KEY_CTRL_A 1 :KEY_CTRL_E 5
                :KEY_CTRL_B 2 :KEY_CTRL_F 6
                :KEY_CTRL_P 16 :KEY_CTRL_N 14
                :KEY_CTRL_W 23 :KEY_CTRL_U 21 :KEY_CTRL_Y 25
                :KEY_CTRL_L 12 :KEY_CTRL_Z 26
                :KEY_BACKSPACE 8 :KEY_BACKSPACE2 127
                :KEY_HOME 1001 :KEY_END 1002
                :KEY_ARROW_LEFT 1003 :KEY_ARROW_RIGHT 1004
                :KEY_ARROW_UP 1005 :KEY_ARROW_DOWN 1006
                :KEY_PGUP 1007 :KEY_PGDN 1008
                :KEY_MOUSE_WHEEL_UP 1009 :KEY_MOUSE_WHEEL_DOWN 1010
                :KEY_MOUSE_LEFT 1011 :KEY_MOUSE_RIGHT 1012
                :KEY_MOUSE_MIDDLE 1013 :KEY_MOUSE_RELEASE 1014
                :KEY_SPACE 32 :MOD_ALT 0 :MOD_MOTION 8
                :EVENT_KEY 1 :EVENT_RESIZE 2 :EVENT_MOUSE 3
                :OUTPUT_NORMAL 1 :INPUT_ESC 4 :INPUT_ALT 1 :INPUT_MOUSE 2
                :ERR_NO_EVENT 0}]
    (each [k v (pairs consts)]
      (tset stub k v))
    (set stub.width-value (or opts.cols opts.width 80))
    (set stub.height-value (or opts.rows opts.height 24))
    (each [_ name (ipairs [:init :shutdown :set_input_mode :set_output_mode
                           :peek_event])]
      (tset stub name (fn [] 0)))
    (tset stub :set_cell
          (fn [x y ch _fg _bg]
            (ensure-screen! stub)
            (when stub.capture?
              (put-utf8-text! stub.screen x y (cell-text (or ch 32))))
            0))
    (tset stub :print
          (fn [x y _fg _bg text]
            (ensure-screen! stub)
            (when stub.capture?
              (put-utf8-text! stub.screen x y text))
            0))
    (tset stub :set_cursor
          (fn [x y]
            (set stub.cursor {:x x :y y :hidden? false})
            0))
    (tset stub :hide_cursor
          (fn []
            (set stub.cursor {:hidden? true})
            0))
    ;; Ctrl-Z suspend would stop the test runner; record the call instead.
    (tset stub :raise_sigtstp (fn []
                                (set stub.sigtstp-count (+ (or stub.sigtstp-count 0) 1))
                                0))
    (tset stub :width (fn [] (or stub.width-value 80)))
    (tset stub :height (fn [] (or stub.height-value 24)))
    (tset stub :clear (fn []
                        (set stub.clear-count (+ (or stub.clear-count 0) 1))
                        (reset-screen! stub)
                        0))
    (tset stub :present (fn []
                          (set stub.present-count (+ (or stub.present-count 0) 1))
                          (when stub.capture?
                            (ensure-screen! stub)
                            (set stub.presented-screen (clone-grid stub.screen)))
                          0))
    (reset-screen! stub)
    (tset package.loaded :termbox2 stub)
    stub))

;; @doc fen.testing.tui.screen-lines
;; kind: function
;; signature: (screen-lines stub ?opts) -> string[]
;; summary: Return captured termbox back-buffer lines, trimming trailing blanks by default.
;; tags: testing tui termbox screen capture
(fn M.screen-lines [stub ?opts]
  "Return the current captured back-buffer lines for a capture-enabled stub.
   Trailing spaces are trimmed by default; pass {:trim-trailing? false} to
   keep full-width rows."
  (let [opts (or ?opts {})
        trim? (not= opts.trim-trailing? false)]
    (assert stub.capture? "screen-lines requires install-termbox-stub! {:capture? true}")
    (ensure-screen! stub)
    (grid-lines stub.screen trim?)))

;; @doc fen.testing.tui.presented-screen-lines
;; kind: function
;; signature: (presented-screen-lines stub ?opts) -> string[]
;; summary: Return the last presented captured screen, or the current screen when no present has occurred.
;; tags: testing tui termbox screen capture
(fn M.presented-screen-lines [stub ?opts]
  "Return the last screen snapshot captured at tb.present, falling back to
   the current back buffer when the test used paint-frame! without presenting."
  (let [opts (or ?opts {})
        trim? (not= opts.trim-trailing? false)]
    (assert stub.capture? "presented-screen-lines requires capture mode")
    (ensure-screen! stub)
    (grid-lines (or stub.presented-screen stub.screen) trim?)))

;; @doc fen.testing.tui.screen-text
;; kind: function
;; signature: (screen-text stub ?opts) -> string
;; summary: Return captured screen lines joined with newlines for compact assertion diagnostics.
;; tags: testing tui termbox screen capture
(fn M.screen-text [stub ?opts]
  (table.concat (M.screen-lines stub ?opts) "\n"))

(fn M.install-markdown-stub! []
  "Install a tiny markdown renderer for tests that only need wrapping/prefixes."
  (tset package.loaded :fen.extensions.tui.markdown
        {:render-text (fn [text _width]
                        [{:text (or text "") :attr 0}])
         :display-len (fn [s] (length (or s "")))}))

(fn M.reset-state! [?opts]
  "Reset persistent TUI state fields used by logic/rendering tests."
  (let [opts (or ?opts {})
        state (require :fen.extensions.tui.state)]
    (set state.tb-cols (or opts.cols 80))
    (set state.tb-rows (or opts.rows 24))
    (set state.tb-initialized? false)
    (set state.input-buf "")
    (set state.input-cursor 0)
    (set state.history [])
    (set state.history-pos 0)
    (set state.history-draft "")
    (set state.transcript [])
    (set state.streaming-assistant-rows {})
    (set state.transcript-layout-cache nil)
    (set state.scroll-offset 0)
    (set state.selection nil)
    (set state.selection-paint nil)
    (set state.copy-status nil)
    (set state.new-content-below? false)
    (set state.last-user-jump-index nil)
    (set state.expand-tool-results? false)
    (set state.markdown? (if (= opts.markdown? nil) false opts.markdown?))
    (set state.hide-thinking-block? false)
    (set state.animations? true)
    (set state.pending-quit? false)
    (set state.alt-pending? false)
    (set state.cancel-pressed? false)
    (set state.dirty? false)
    (set state.force-redraw? false)
    (set state.spinner-ticks 0)
    (set state.spinner-interval-ticks 8)
    (set state.completion nil)
    (set state.errors [])
    (set state.errors-visible? false)
    (set state.status-info
         {:model nil :provider nil
          :cum-input 0 :cum-output 0
          :cum-cache-read 0 :cum-cache-write 0
          :last-input 0 :start-ms 0
          :running-label nil :thinking? false :retrying? false
          :retry-attempt 0 :retry-max-attempts 0 :retry-delay-ms 0
          :retry-reason nil :cancelling? false :turn-start 0
          :spin-frame 0 :steering-queued 0 :follow-up-queued 0})
    state))

M
