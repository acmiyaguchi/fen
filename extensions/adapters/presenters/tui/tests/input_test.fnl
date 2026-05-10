;; Focused tests for TUI input wrapping and cursor geometry.

(local tui-test (require :fen.testing.tui))
(tui-test.install-termbox-stub!)
(tui-test.install-markdown-stub!)

(local state (require :fen.extensions.tui.state))
(local input (require :fen.extensions.tui.input))

(fn reset! []
  (set state.tb-cols 80)
  (set state.tb-rows 24)
  (set state.input-buf "")
  (set state.input-cursor 0)
  (set state.history [])
  (set state.history-pos 0)
  (set state.history-draft ""))

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
