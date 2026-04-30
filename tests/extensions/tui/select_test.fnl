;; Pure-logic tests for the api.ui.select state machine. Drives make-state
;; / step! / filtered with synthetic key descriptors so we don't need
;; termbox; the inner event loop is covered by the visual smoke test.

(let [stub {}
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
  (each [_ name (ipairs [:init :shutdown :width :height
                         :set_input_mode :set_output_mode
                         :set_cell :set_cursor :hide_cursor
                         :print :clear :present :peek_event])]
    (tset stub name (fn [] 0)))
  (tset package.loaded :termbox2 stub))

(tset package.loaded :extensions.tui.markdown
  {:render-text (fn [text _width]
                  [{:text text :attr 0}])
   :display-len (fn [s] (length (or s "")))})

(local select (require :extensions.tui.select))

(fn make [choices]
  (select.make-state {:label "pick one" :choices choices}))

(fn char [text] {:kind :char :text text})

(describe "select.filtered"
  (fn []
    (it "returns all choices when filter-text is empty"
      (fn []
        (let [s (make [{:label "a"} {:label "b"} {:label "c"}])]
          (assert.are.equal 3 (length (select.filtered s))))))

    (it "matches substrings of label case-insensitively"
      (fn []
        (let [s (make [{:label "Bash"} {:label "Read"} {:label "Edit"}])]
          (set s.filter-text "EA")
          (let [matches (select.filtered s)]
            (assert.are.equal 1 (length matches))
            (assert.are.equal "Read" (. matches 1 :label))))))

    (it "matches description as well as label"
      (fn []
        (let [s (make [{:label "x" :description "shell command"}
                       {:label "y" :description "edit file"}])]
          (set s.filter-text "shell")
          (let [matches (select.filtered s)]
            (assert.are.equal 1 (length matches))
            (assert.are.equal "x" (. matches 1 :label))))))))

(describe "select.step!"
  (fn []
    (it "down moves cursor and clamps to filtered length"
      (fn []
        (let [s (make [{:label "a"} {:label "b"} {:label "c"}])]
          (select.step! s {:kind :down})
          (assert.are.equal 2 s.cursor)
          (select.step! s {:kind :down})
          (assert.are.equal 3 s.cursor)
          ;; further down clamps at the end
          (select.step! s {:kind :down})
          (assert.are.equal 3 s.cursor))))

    (it "up clamps at 1"
      (fn []
        (let [s (make [{:label "a"} {:label "b"}])]
          (select.step! s {:kind :up})
          (assert.are.equal 1 s.cursor))))

    (it "char appends to filter and resets cursor"
      (fn []
        (let [s (make [{:label "alpha"} {:label "beta"} {:label "gamma"}])]
          (select.step! s {:kind :down})
          (select.step! s (char "b"))
          (assert.are.equal "b" s.filter-text)
          (assert.are.equal 1 s.cursor)
          (let [matches (select.filtered s)]
            (assert.are.equal 1 (length matches))
            (assert.are.equal "beta" (. matches 1 :label))))))

    (it "backspace strips one byte from filter"
      (fn []
        (let [s (make [{:label "a"} {:label "b"}])]
          (select.step! s (char "a"))
          (select.step! s (char "b"))
          (assert.are.equal "ab" s.filter-text)
          (select.step! s {:kind :bs})
          (assert.are.equal "a" s.filter-text)
          (select.step! s {:kind :bs})
          (assert.are.equal "" s.filter-text)
          (select.step! s {:kind :bs})
          (assert.are.equal "" s.filter-text))))

    (it "enter sets result to the cursored choice and marks done"
      (fn []
        (let [picks [{:label "first" :value :a}
                     {:label "second" :value :b}
                     {:label "third" :value :c}]
              s (make picks)]
          (select.step! s {:kind :down})
          (select.step! s {:kind :enter})
          (assert.is_true s.done?)
          (assert.are.equal :b (. s.result :value)))))

    (it "esc sets result to nil and marks done"
      (fn []
        (let [s (make [{:label "a"}])]
          (select.step! s {:kind :esc})
          (assert.is_true s.done?)
          (assert.is_nil s.result))))

    (it "enter on an empty filtered list marks done with nil result"
      (fn []
        (let [s (make [{:label "alpha"}])]
          (select.step! s (char "z"))
          (assert.are.equal 0 (length (select.filtered s)))
          (select.step! s {:kind :enter})
          (assert.is_true s.done?)
          (assert.is_nil s.result))))))
