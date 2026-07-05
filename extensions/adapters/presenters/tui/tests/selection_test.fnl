;; Tests for native transcript selection geometry and extraction.

(local tui-test (require :fen.testing.tui))
(tui-test.install-termbox-stub!)

(local state (require :fen.extensions.tui.state))
(local selection (require :fen.extensions.tui.selection))

(fn reset! []
  (set state.selection nil)
  (set state.selection-paint nil))

(describe "tui selection geometry"
  (fn []
    (before_each reset!)

    (it "normalizes anchor/cursor into reading order"
      (fn []
        (let [norm (selection.normalized {:anchor {:x 5 :y 3}
                                          :cursor {:x 2 :y 1}})]
          (assert.are.same {:x 2 :y 1} norm.start)
          (assert.are.same {:x 5 :y 3} norm.end))))

    (it "orders by column when on the same row"
      (fn []
        (let [norm (selection.normalized {:anchor {:x 8 :y 2}
                                          :cursor {:x 3 :y 2}})]
          (assert.are.same {:x 3 :y 2} norm.start)
          (assert.are.same {:x 8 :y 2} norm.end))))

    (it "returns a single-row column range"
      (fn []
        (let [sel {:anchor {:x 2 :y 1} :cursor {:x 5 :y 1}}
              (from to) (selection.row-range sel 1 10)]
          (assert.are.equal 2 from)
          (assert.are.equal 5 to))))

    (it "extends middle rows of a multi-row selection to the full width"
      (fn []
        (let [sel {:anchor {:x 3 :y 1} :cursor {:x 4 :y 3}}]
          ;; first row: from anchor col to end of row
          (let [(from to) (selection.row-range sel 1 10)]
            (assert.are.equal 3 from)
            (assert.are.equal 9 to))
          ;; middle row: whole row
          (let [(from to) (selection.row-range sel 2 10)]
            (assert.are.equal 0 from)
            (assert.are.equal 9 to))
          ;; last row: start of row to cursor col
          (let [(from to) (selection.row-range sel 3 10)]
            (assert.are.equal 0 from)
            (assert.are.equal 4 to)))))

    (it "returns nil for rows outside the selection"
      (fn []
        (let [sel {:anchor {:x 1 :y 2} :cursor {:x 4 :y 2}}]
          (assert.is_nil (selection.row-range sel 1 10))
          (assert.is_nil (selection.row-range sel 3 10)))))

    (it "returns nil for zero-width rows"
      (fn []
        (let [sel {:anchor {:x 0 :y 0} :cursor {:x 5 :y 0}}]
          (assert.is_nil (selection.row-range sel 0 0)))))

    (it "recognizes only painted transcript text as selectable"
      (fn []
        (let [snapshot {:rows {2 "hello"} :min-y 2 :max-y 2}]
          (assert.is_true (selection.selectable-cell? 0 2 snapshot))
          (assert.is_true (selection.selectable-cell? 4 2 snapshot))
          (assert.is_false (selection.selectable-cell? 5 2 snapshot))
          (assert.is_false (selection.selectable-cell? 0 0 snapshot)))))

    (it "clamps drag endpoints to the painted transcript snapshot"
      (fn []
        (let [snapshot {:rows {2 "hello" 3 "world"} :min-y 2 :max-y 3}
              pt (selection.clamp-to-snapshot 99 99 snapshot)]
          (assert.are.same {:x 4 :y 3} pt))))))

(describe "tui selection lifecycle"
  (fn []
    (before_each reset!)

    (it "start/update/finish drive an active selection"
      (fn []
        (assert.is_false (selection.active?))
        (selection.start! 2 1)
        (assert.is_true (selection.active?))
        (assert.is_true state.selection.dragging?)
        (selection.update! 6 1)
        (assert.are.same {:x 6 :y 1} state.selection.cursor)
        (selection.finish!)
        (assert.is_false state.selection.dragging?)
        (assert.is_true (selection.active?))))

    (it "clear! drops the selection and reports prior presence"
      (fn []
        (selection.start! 0 0)
        (assert.is_true (selection.clear!))
        (assert.is_false (selection.active?))
        (assert.is_false (selection.clear!))))))

(describe "tui selection extraction"
  (fn []
    (before_each reset!)

    (fn snap [rows] {:rows rows})

    (it "extracts a single-row substring codepoint-aware"
      (fn []
        (let [sel {:anchor {:x 2 :y 0} :cursor {:x 5 :y 0}}
              text (selection.extract sel (snap {0 "hello world"}))]
          ;; cols 2..5 inclusive of "hello world" -> "llo "
          (assert.are.equal "llo " text))))

    (it "joins multiple rows with newlines"
      (fn []
        (let [sel {:anchor {:x 3 :y 0} :cursor {:x 2 :y 2}}
              text (selection.extract sel (snap {0 "abcdefg"
                                                 1 "second"
                                                 2 "third"}))]
          ;; row0: from col3 to end -> "defg"; row1 whole -> "second";
          ;; row2: col0..2 -> "thi"
          (assert.are.equal "defg\nsecond\nthi" text))))

    (it "preserves blank lines for empty rows in range"
      (fn []
        (let [sel {:anchor {:x 0 :y 0} :cursor {:x 2 :y 2}}
              text (selection.extract sel (snap {0 "aaa"
                                                 2 "ccc"}))]
          (assert.are.equal "aaa\n\nccc" text))))

    (it "handles multibyte codepoints as single columns"
      (fn []
        (let [sel {:anchor {:x 0 :y 0} :cursor {:x 2 :y 0}}
              text (selection.extract sel (snap {0 "café"}))]
          ;; cols 0..2 of c,a,f,é -> "caf"
          (assert.are.equal "caf" text))))

    (it "returns empty for an incomplete selection"
      (fn []
        (assert.are.equal "" (selection.extract {:anchor {:x 0 :y 0}} (snap {0 "x"})))
        (assert.are.equal "" (selection.extract nil (snap {0 "x"})))))

    (it "records paint rows and extracts via selected-text"
      (fn []
        (selection.begin-paint!)
        (selection.record-row! 0 "hello")
        (selection.record-row! 1 "world")
        (set state.selection {:anchor {:x 0 :y 0} :cursor {:x 2 :y 1}})
        (assert.are.equal "hello\nwor" (selection.selected-text))))))
