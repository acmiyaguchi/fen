;; Helpers for fast in-process TUI tests.
;; These deliberately avoid the real terminal by installing a termbox2 stub
;; before tests require TUI modules.

(local M {})

(fn M.install-termbox-stub! []
  "Install a safe termbox2 test double in package.loaded and return it."
  (let [stub {}
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
                :KEY_BACKSPACE 8 :KEY_BACKSPACE2 127
                :KEY_HOME 1001 :KEY_END 1002
                :KEY_ARROW_LEFT 1003 :KEY_ARROW_RIGHT 1004
                :KEY_ARROW_UP 1005 :KEY_ARROW_DOWN 1006
                :KEY_PGUP 1007 :KEY_PGDN 1008
                :KEY_MOUSE_WHEEL_UP 1009 :KEY_MOUSE_WHEEL_DOWN 1010
                :KEY_SPACE 32 :MOD_ALT 0
                :EVENT_KEY 1 :EVENT_RESIZE 2 :EVENT_MOUSE 3
                :OUTPUT_NORMAL 1 :INPUT_ALT 1 :INPUT_MOUSE 2
                :ERR_NO_EVENT 0}]
    (each [k v (pairs consts)]
      (tset stub k v))
    (each [_ name (ipairs [:init :shutdown :set_input_mode :set_output_mode
                           :set_cell :set_cursor :hide_cursor :print
                           :peek_event])]
      (tset stub name (fn [] 0)))
    (tset stub :width (fn [] (or stub.width-value 80)))
    (tset stub :height (fn [] (or stub.height-value 24)))
    (tset stub :clear (fn []
                        (set stub.clear-count (+ (or stub.clear-count 0) 1))
                        0))
    (tset stub :present (fn []
                          (set stub.present-count (+ (or stub.present-count 0) 1))
                          0))
    (tset package.loaded :termbox2 stub)
    stub))

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
