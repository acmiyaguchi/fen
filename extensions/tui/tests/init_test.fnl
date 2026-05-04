;; Tests for tui.tui pure-logic helpers (spinner, timer, append-event
;; side effects on status-info). Avoids termbox2 entirely — we install a
;; full stub into package.loaded before requiring tui.tui so the module
;; load succeeds without touching the real C library.

;; ---- termbox2 stub ----
;; tui.tnl does `(local tb (require :termbox2))` at module load and
;; references constants like tb.GREEN, tb.CYAN, etc. Install a minimal
;; stub that returns sensible values for everything so the module
;; compiles and loads.
(local tb-stub {})
(let [stub tb-stub
      ;; Numeric constants used in color/attribute construction.
      ;; The actual values don't matter for pure-logic tests — they
      ;; just can't be nil or the bor/band calls would error.
      consts {:DEFAULT 0 :CYAN 6 :GREEN 2 :RED 1 :YELLOW 3 :WHITE 7
              :BOLD 1 :DIM 2 :REVERSE 4
              :KEY_ENTER 13 :KEY_CTRL_C 3 :KEY_CTRL_D 4
              :KEY_CTRL_J 10 :KEY_CTRL_O 15 :KEY_CTRL_T 20
              :KEY_CTRL_A 1 :KEY_CTRL_E 5
              :KEY_CTRL_B 2 :KEY_CTRL_F 6
              :KEY_CTRL_P 16 :KEY_CTRL_N 14
              :KEY_CTRL_W 23 :KEY_CTRL_U 21
              :KEY_BACKSPACE 8 :KEY_BACKSPACE2 127
              :KEY_HOME 1 :KEY_END 6
              :KEY_ARROW_LEFT 0 :KEY_ARROW_RIGHT 0
              :KEY_ARROW_UP 0 :KEY_ARROW_DOWN 0
              :KEY_PGUP 0 :KEY_PGDN 0
              :KEY_MOUSE_WHEEL_UP 0 :KEY_MOUSE_WHEEL_DOWN 0
              :KEY_SPACE 32
              :MOD_ALT 0
              :EVENT_KEY 1 :EVENT_RESIZE 2 :EVENT_MOUSE 3
              :OUTPUT_NORMAL 1
              :INPUT_ALT 1 :INPUT_MOUSE 2
              :ERR_NO_EVENT 0}]
  (each [k v (pairs consts)]
    (tset stub k v))
  ;; Stub functions that tui.tui calls. Return safe no-op values.
  (each [_ name (ipairs [:init :shutdown :width :height
                         :set_input_mode :set_output_mode
                         :set_cell :set_cursor :hide_cursor
                         :print :clear :present :peek_event])]
    (tset stub name
          (fn []
            (if (= name :width) 80
                (= name :height) 24
                (= name :present) (do (set stub.present-count (+ (or stub.present-count 0) 1)) 0)
                (= name :clear) (do (set stub.clear-count (+ (or stub.clear-count 0) 1)) 0)
                0))))
  (tset package.loaded :termbox2 stub))

;; ---- tui.markdown stub ----
;; tui.tui requires tui.markdown for rendering; provide a minimal stub.
(tset package.loaded :fen.extensions.tui.markdown
  {:render-text (fn [text _width]
                  [{:text text :attr 0}])
   :display-len (fn [s] (length (or s "")))})

(local state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))
(local transcript (require :fen.extensions.tui.panels.transcript))
(local busy-panel (require :fen.extensions.tui.panels.busy))
(local ingest (require :fen.extensions.tui.ingest))
(local paint (require :fen.extensions.tui.paint))

;; Reset all mutable state between tests so one test's turn-start/spin-frame
;; doesn't leak into the next.
(fn reset-state! []
  (set state.transcript [])
  (set state.scroll-offset 0)
  (set state.input-buf "")
  (set state.input-cursor 0)
  (set state.history [])
  (set state.history-pos 0)
  (set state.history-draft "")
  (set state.pending-quit? false)
  (set state.alt-pending? false)
  (set state.cancel-pressed? false)
  (set state.expand-tool-results? false)
  (set state.markdown? true)
  (set state.hide-thinking-block? false)
  (set state.animations? true)
  (set state.status-info
       {:model nil :provider nil
        :cum-input 0 :cum-output 0
        :cum-cache-read 0 :cum-cache-write 0
        :last-input 0
        :start-ms 0
        :running-label nil
        :thinking? false
        :cancelling? false
        :turn-start 0
        :spin-frame 0})
  (set state.dirty? false)
  (set state.force-redraw? false)
  (set state.spinner-ticks 0)
  (set state.spinner-interval-ticks 8)
  (set tb-stub.present-count 0)
  (set tb-stub.clear-count 0))

(describe "busy-panel.spin-char"
  (fn []
    (before_each reset-state!)

    (it "returns the first braille frame at spin-frame 0"
      (fn []
        (set state.status-info.spin-frame 0)
        ;; The first frame is ⠋ (U+280B).
        (assert.are.equal "⠋" (busy-panel.spin-char))))

    (it "cycles through frames modulo 10"
      (fn []
        ;; Frame 9 → index 10 → last frame ⠏
        (set state.status-info.spin-frame 9)
        (assert.are.equal "⠏" (busy-panel.spin-char))
        ;; Frame 10 → wraps to index 1 → ⠋ again
        (set state.status-info.spin-frame 10)
        (assert.are.equal "⠋" (busy-panel.spin-char))))

    (it "handles large frame numbers by wrapping"
      (fn []
        ;; 73 % 10 = 3 → index 4 → ⠸
        (set state.status-info.spin-frame 73)
        (assert.are.equal "⠸" (busy-panel.spin-char))))

    (it "returns a static glyph when animations are disabled"
      (fn []
        (set state.animations? false)
        (set state.status-info.spin-frame 9)
        (assert.are.equal "•" (busy-panel.spin-char))))))

(describe "busy-panel.turn-elapsed"
  (fn []
    (before_each reset-state!)

    (it "returns empty string when turn-start is 0 (idle)"
      (fn []
        (set state.status-info.turn-start 0)
        (assert.are.equal "" (busy-panel.turn-elapsed))))

    (it "returns seconds since turn-start"
      (fn []
        (let [now (os.time)]
          (set state.status-info.turn-start (- now 42))
          (assert.are.equal "42s" (busy-panel.turn-elapsed)))))

    (it "returns 0s when turn-start equals now"
      (fn []
        (set state.status-info.turn-start (os.time))
        (assert.are.equal "0s" (busy-panel.turn-elapsed))))))

(describe "tui dirty redraw scheduling"
  (fn []
    (before_each reset-state!)

    (it "invalidate! marks the frame dirty"
      (fn []
        (assert.is_false state.dirty?)
        (paint.invalidate!)
        (assert.is_true state.dirty?)))

    (it "invalidate-full! marks both force-redraw and dirty"
      (fn []
        (paint.invalidate-full!)
        (assert.is_true state.dirty?)
        (assert.is_true state.force-redraw?)))

    (it "ingest appends invalidate instead of immediate redraw"
      (fn []
        (ingest.append-event {:type :info :text "hello"})
        (assert.is_true state.dirty?)
        (assert.are.equal 1 (length state.transcript))))

    (it "redraw-if-needed! skips clean idle frames"
      (fn []
        (set state.tb-initialized? true)
        (paint.redraw-if-needed!)
        (assert.are.equal 0 (or tb-stub.present-count 0))))

    (it "redraw-if-needed! presents once for dirty frames"
      (fn []
        (set state.tb-initialized? true)
        (paint.invalidate!)
        (paint.redraw-if-needed!)
        (assert.are.equal 1 (or tb-stub.present-count 0))
        (assert.is_false state.dirty?)))

    (it "redraw-if-needed! blank-presents then repaints for force redraw"
      (fn []
        (set state.tb-initialized? true)
        (paint.invalidate-full!)
        (paint.redraw-if-needed!)
        (assert.are.equal 2 (or tb-stub.present-count 0))
        (assert.is_false state.force-redraw?)))

    (it "busy spinner advances only after the configured tick interval"
      (fn []
        (set state.status-info.thinking? true)
        (set state.spinner-interval-ticks 3)
        (paint.advance-spinner-if-due!)
        (assert.are.equal 0 state.status-info.spin-frame)
        (paint.advance-spinner-if-due!)
        (assert.are.equal 0 state.status-info.spin-frame)
        (paint.advance-spinner-if-due!)
        (assert.are.equal 1 state.status-info.spin-frame)
        (assert.is_true state.dirty?)))

    (it "spinner tick counter resets while idle"
      (fn []
        (set state.status-info.thinking? true)
        (paint.advance-spinner-if-due!)
        (assert.are.equal 1 state.spinner-ticks)
        (set state.status-info.thinking? false)
        (paint.advance-spinner-if-due!)
        (assert.are.equal 0 state.spinner-ticks)))

    (it "does not advance or invalidate for spinner frames when animations are disabled"
      (fn []
        (set state.animations? false)
        (set state.status-info.thinking? true)
        (set state.spinner-interval-ticks 1)
        (set state.dirty? false)
        (paint.advance-spinner-if-due!)
        (assert.are.equal 0 state.spinner-ticks)
        (assert.are.equal 0 state.status-info.spin-frame)
        (assert.is_false state.dirty?)))

    (it "uses a long event timeout when clean and idle"
      (fn []
        (assert.are.equal 300 (tui.peek-timeout-ms (fn [] false)))))

    (it "uses a short event timeout while dirty, busy, or resolving alt"
      (fn []
        (set state.dirty? true)
        (assert.are.equal 30 (tui.peek-timeout-ms (fn [] false)))
        (set state.dirty? false)
        (assert.are.equal 30 (tui.peek-timeout-ms (fn [] true)))
        (set state.alt-pending? true)
        (assert.are.equal 30 (tui.peek-timeout-ms (fn [] false)))))))

(describe "ingest.append-event status-info side effects"
  (fn []
    (before_each reset-state!)

    (it "stamps turn-start on first :llm-start of a turn"
      (fn []
        (set state.status-info.turn-start 0)
        (ingest.append-event {:type :llm-start})
        (assert.is_truthy (> state.status-info.turn-start 0))
        (assert.is_true state.status-info.thinking?)))

    (it "does not overwrite turn-start on subsequent :llm-start"
      (fn []
        ;; First llm-start stamps turn-start.
        (ingest.append-event {:type :llm-start})
        (let [first-start state.status-info.turn-start]
          ;; Second llm-start (next iteration of the tool loop) should
          ;; NOT reset the timer.
          (ingest.append-event {:type :llm-start})
          (assert.are.equal first-start state.status-info.turn-start))))

    (it "clears turn-start and thinking? on final :assistant-text"
      (fn []
        (ingest.append-event {:type :llm-start})
        (assert.is_truthy (> state.status-info.turn-start 0))
        (ingest.append-event {:type :assistant-text :text "done"})
        (assert.are.equal 0 state.status-info.turn-start)
        (assert.is_false state.status-info.thinking?)))

    (it "keeps turn active for non-final thinking and clears on final thinking"
      (fn []
        (ingest.append-event {:type :llm-start})
        (ingest.append-event {:type :assistant-thinking :text "step" :final? false})
        (assert.is_truthy (> state.status-info.turn-start 0))
        (ingest.append-event {:type :assistant-thinking :text "done thinking" :final? true})
        (assert.are.equal 0 state.status-info.turn-start)
        (assert.is_false state.status-info.thinking?)))

    (it "clears turn-start and thinking? on :error"
      (fn []
        (ingest.append-event {:type :llm-start})
        (ingest.append-event {:type :error :error "boom"})
        (assert.are.equal 0 state.status-info.turn-start)
        (assert.is_false state.status-info.thinking?)))

    (it "clears turn-start and thinking? on :cancelled"
      (fn []
        (ingest.append-event {:type :llm-start})
        (ingest.append-event {:type :cancelled})
        (assert.are.equal 0 state.status-info.turn-start)
        (assert.is_false state.status-info.thinking?)
        (assert.is_false state.status-info.cancelling?)))

    (it "normalizes extension-loaded events into durable info rows"
      (fn []
        (ingest.append-event {:type :extension-loaded :name :builtin_tools})
        (assert.are.equal :info (. state.transcript 1 :type))
        (assert.are.equal "extension-loaded: builtin_tools"
                          (. state.transcript 1 :text))
        (let [rows (transcript.viewport-lines 80 1)]
          (assert.are.equal "extension-loaded: builtin_tools" (. rows 1 :text)))))

    (it "sets running-label on :tool-call and clears on :tool-result"
      (fn []
        (ingest.append-event {:type :llm-start})
        (ingest.append-event {:type :tool-call
                           :name :bash
                           :arguments {:cmd "ls"}
                           :id "tc-1"})
        (assert.are.equal "$ ls" state.status-info.running-label)
        ;; Turn-start should still be alive (turn in progress).
        (assert.is_truthy (> state.status-info.turn-start 0))
        (ingest.append-event {:type :tool-result
                           :tool-call-id "tc-1"
                           :result {:content [{:type :text :text "file1\nfile2"}]}})
        (assert.is_nil state.status-info.running-label)
        ;; Turn still alive — the agent loop may do another LLM call.
        (assert.is_truthy (> state.status-info.turn-start 0))))

    (it "coalesces assistant text deltas into one transcript row"
      (fn []
        (ingest.append-event {:type :llm-start})
        (ingest.append-event {:type :assistant-text-delta :content-index 1 :delta "he"})
        (ingest.append-event {:type :assistant-text-delta :content-index 1 :delta "llo"})
        (assert.are.equal 1 (length state.transcript))
        (assert.are.equal :assistant-text (. state.transcript 1 :type))
        (assert.are.equal "hello" (. state.transcript 1 :text))
        (assert.is_true (. state.transcript 1 :streaming?))
        (ingest.append-event {:type :assistant-stream-end :final? true})
        (assert.is_nil (. state.transcript 1 :streaming?))
        (assert.is_true (. state.transcript 1 :final?))
        (assert.are.equal 0 state.status-info.turn-start)
        (assert.is_false state.status-info.thinking?)))))

(describe "tui thinking rendering"
  (fn []
    (before_each reset-state!)

    (it "renders visible thinking rows in dim transcript output"
      (fn []
        (set state.markdown? false)
        (ingest.append-event {:type :assistant-thinking
                           :text "reasoning trace"
                           :spacer-after? true})
        (let [rows (transcript.viewport-lines 80 3)]
          (assert.are.equal "…   reasoning trace" (. rows 1 :text))
          (assert.are.equal "" (. rows 2 :text)))))

    (it "collapses thinking rows when hide-thinking-block? is true"
      (fn []
        (set state.hide-thinking-block? true)
        (ingest.append-event {:type :assistant-thinking :text "secret"})
        (let [rows (transcript.viewport-lines 80 2)]
          (assert.are.equal "…   Thinking..." (. rows 1 :text)))))))

(describe "tui extension wiring (issue #15 Step 3b/3c)"
  (fn []
    (local extensions (require :fen.core.extensions))

    (it "registers /expand /markdown /animations /thinking with owner :tui"
      (fn []
        (let [names {}]
          (each [name rec (pairs extensions.commands-extra)]
            (when (= rec.owner :tui)
              (tset names name true)))
          (assert.is_true (. names :expand))
          (assert.is_true (. names :markdown))
          (assert.is_true (. names :animations))
          (assert.is_true (. names :thinking)))))

    (it "registers an active presenter named :tui"
      (fn []
        (var found nil)
        (each [_ p (ipairs extensions.presenters)]
          (when (= p.name :tui) (set found p)))
        (assert.is_not_nil found)
        (assert.is_true found.active?)))

    (it ":reset-conversation event clears the transcript"
      (fn []
        (reset-state!)
        (ingest.append-event {:type :info :text "stale"})
        (assert.are.equal 1 (length state.transcript))
        (extensions.emit {:type :reset-conversation})
        (assert.are.equal 0 (length state.transcript))))

    (it ":message-appended event stays out of the transcript"
      (fn []
        (reset-state!)
        (extensions.emit {:type :message-appended
                          :message {:role :user :content [{:type :text :text "hi"}]}
                          :index 1})
        (assert.are.equal 0 (length state.transcript))))

    (it ":set-status-info event applies the partial info"
      (fn []
        (reset-state!)
        (extensions.emit
          {:type :set-status-info
           :info {:model :gpt-test :steering-queued 7}})
        (assert.are.equal :gpt-test state.status-info.model)
        (assert.are.equal 7 state.status-info.steering-queued)))

    (it "/markdown command toggles state.markdown? via dispatch"
      (fn []
        (reset-state!)
        (set state.markdown? false)
        (extensions.dispatch-command "/markdown on" {})
        (assert.is_true state.markdown?)
        (extensions.dispatch-command "/markdown off" {})
        (assert.is_false state.markdown?)))

    (it "/expand command toggles state.expand-tool-results? via dispatch"
      (fn []
        (reset-state!)
        (extensions.dispatch-command "/expand on" {})
        (assert.is_true state.expand-tool-results?)
        (extensions.dispatch-command "/expand off" {})
        (assert.is_false state.expand-tool-results?)))

    (it "/animations command toggles state.animations? via dispatch"
      (fn []
        (reset-state!)
        (extensions.dispatch-command "/animations off" {})
        (assert.is_false state.animations?)
        (extensions.dispatch-command "/animations on" {})
        (assert.is_true state.animations?)))))