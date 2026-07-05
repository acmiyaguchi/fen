;; Focused tests for TUI input wrapping and cursor geometry.

(local tui-test (require :fen.testing.tui))
(tui-test.install-termbox-stub!)
(tui-test.install-markdown-stub!)

(local state (require :fen.extensions.tui.state))
(local input (require :fen.extensions.tui.input))
(local tb (require :termbox2))
(local selection (require :fen.extensions.tui.selection))
(local clipboard (require :fen.extensions.tui.clipboard))

(fn reset! []
  (set state.tb-cols 80)
  (set state.tb-rows 24)
  (set state.input-buf "")
  (set state.input-cursor 0)
  (set state.history [])
  (set state.history-pos 0)
  (set state.history-draft "")
  (set state.expand-tool-results? false)
  (set state.hide-thinking-block? false)
  (set state.api {:emitted []
                  :emit (fn [ev]
                          (table.insert state.api.emitted ev))}))

(fn row-texts [rows]
  (let [out []]
    (each [_ row (ipairs rows)]
      (table.insert out row.text))
    out))

(describe "tui.input display geometry"
  (fn []
    (before_each reset!)

    (it "wraps soft lines using prompt and continuation widths"
      (fn []
        (let [rows (input.input-display-rows "abcdef" 6 6)]
          (assert.are.same ["abcd" "ef"] (row-texts rows))
          (assert.are.equal true (. rows 1 :first?))
          (assert.are.equal false (. rows 2 :first?)))))

    (it "preserves explicit newline rows"
      (fn []
        (let [rows (input.input-display-rows "one\ntwo" 12 7)]
          (assert.are.same ["one" "two"] (row-texts rows))
          (assert.are.equal 0 (. rows 1 :start))
          (assert.are.equal 4 (. rows 2 :start)))))

    (it "adds an empty continuation row when the cursor lands at a wrap boundary"
      (fn []
        (let [rows (input.input-display-rows "abcd" 6 4)]
          (assert.are.same ["abcd" ""] (row-texts rows))
          (let [(row col) (input.cursor-display-pos rows 4)]
            (assert.are.equal 1 row)
            (assert.are.equal 0 col)))))

    (it "maps cursor position through wrapped rows"
      (fn []
        (let [rows (input.input-display-rows "abcdef" 6 5)
              (row col) (input.cursor-display-pos rows 5)]
          (assert.are.equal 1 row)
          (assert.are.equal 1 col))))))

(describe "tui.input key dispatch"
  (fn []
    (before_each reset!)

    (it "ctrl-o toggles expanded tool-result rendering"
      (fn []
        (assert.is_false state.expand-tool-results?)
        (input.handle-key {:key 0x0f :ch 0 :mod 0} (fn [_] nil) nil nil)
        (assert.is_true state.expand-tool-results?)
        (assert.are.same [{:type :redraw}] state.api.emitted)
        (input.handle-key {:key 0x0f :ch 0 :mod 0} (fn [_] nil) nil nil)
        (assert.is_false state.expand-tool-results?)))

    (it "ctrl-l emits a hard-refresh request without quitting"
      (fn []
        (let [quit? (input.handle-key {:key 0x0c :ch 0 :mod 0} (fn [_] nil) nil nil)]
          (assert.is_false quit?)
          (assert.are.same [{:type :hard-refresh}] state.api.emitted))))

    (it "ctrl-z emits a suspend request without quitting"
      (fn []
        (let [quit? (input.handle-key {:key 0x1a :ch 0 :mod 0} (fn [_] nil) nil nil)]
          (assert.is_false quit?)
          (assert.are.same [{:type :suspend}] state.api.emitted))))))

(describe "tui.input mouse selection"
  (fn []
    (var captured nil)
    (var saved-write clipboard.write!)
    (before_each (fn []
                   (reset!)
                   (set state.selection nil)
                   (set state.selection-paint nil)
                   (set state.copy-status nil)
                   (set state.scroll-offset 0)
                   (set captured nil)
                   (set clipboard.write! (fn [s] (set captured s)))))
    (after_each (fn [] (set clipboard.write! saved-write)))

    (fn seed-selection-row! []
      (selection.begin-paint!)
      (selection.record-row! 2 "hello world"))

    (it "wheel up/down scrolls the transcript"
      (fn []
        ;; Seed enough transcript rows that scroll-offset has room to move.
        (set state.transcript [])
        (for [i 1 100]
          (table.insert state.transcript {:type :user :text (.. "line " i)}))
        (set state.transcript-layout-cache nil)
        (set state.scroll-offset 5)
        (input.handle-mouse {:key tb.KEY_MOUSE_WHEEL_UP :x 0 :y 0 :mod 0})
        (assert.are.equal 8 state.scroll-offset)
        (input.handle-mouse {:key tb.KEY_MOUSE_WHEEL_DOWN :x 0 :y 0 :mod 0})
        (assert.are.equal 5 state.scroll-offset)))

    (it "left press starts a selection anchor on painted transcript text"
      (fn []
        (seed-selection-row!)
        (input.handle-mouse {:key tb.KEY_MOUSE_LEFT :x 3 :y 2 :mod 0})
        (assert.is_true (selection.active?))
        (assert.are.same {:x 3 :y 2} state.selection.anchor)))

    (it "left press outside transcript text does not start selection"
      (fn []
        (seed-selection-row!)
        ;; Status row / panel area: not in the transcript snapshot.
        (input.handle-mouse {:key tb.KEY_MOUSE_LEFT :x 0 :y 0 :mod 0})
        (assert.is_false (selection.active?))
        ;; Empty area to the right of the row text.
        (input.handle-mouse {:key tb.KEY_MOUSE_LEFT :x 60 :y 2 :mod 0})
        (assert.is_false (selection.active?))))

    (it "drag motion extends the selection and clamps to transcript text"
      (fn []
        (seed-selection-row!)
        (input.handle-mouse {:key tb.KEY_MOUSE_LEFT :x 3 :y 2 :mod 0})
        (input.handle-mouse {:key tb.KEY_MOUSE_LEFT :x 70 :y 10 :mod tb.MOD_MOTION})
        ;; Dragging below/right of the transcript clamps to the last painted
        ;; transcript cell instead of selecting input/status rows.
        (assert.are.same {:x 10 :y 2} state.selection.cursor)))

    (it "release over a real span copies via OSC 52 and records status"
      (fn []
        (seed-selection-row!)
        (input.handle-mouse {:key tb.KEY_MOUSE_LEFT :x 0 :y 2 :mod 0})
        (input.handle-mouse {:key tb.KEY_MOUSE_LEFT :x 4 :y 2 :mod tb.MOD_MOTION})
        (input.handle-mouse {:key tb.KEY_MOUSE_RELEASE :x 4 :y 2 :mod 0})
        (assert.are.equal (clipboard.osc52 "hello") captured)
        (assert.is_true state.copy-status.ok?)
        (assert.are.equal 5 state.copy-status.bytes)))

    (it "a plain click with no span clears selection and does not copy"
      (fn []
        (seed-selection-row!)
        (input.handle-mouse {:key tb.KEY_MOUSE_LEFT :x 1 :y 2 :mod 0})
        (input.handle-mouse {:key tb.KEY_MOUSE_RELEASE :x 1 :y 2 :mod 0})
        (assert.is_nil captured)
        (assert.is_false (selection.active?))))

    (it "scrolling clears an active selection"
      (fn []
        (seed-selection-row!)
        (input.handle-mouse {:key tb.KEY_MOUSE_LEFT :x 0 :y 2 :mod 0})
        (input.handle-mouse {:key tb.KEY_MOUSE_LEFT :x 4 :y 2 :mod tb.MOD_MOTION})
        (assert.is_true (selection.active?))
        (input.handle-mouse {:key tb.KEY_MOUSE_WHEEL_UP :x 0 :y 0 :mod 0})
        (assert.is_false (selection.active?))))))
