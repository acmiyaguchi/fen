;; Pure-logic tests for the api.ui.select state machine. Drives make-state
;; / step! / filtered with synthetic key descriptors so we don't need
;; termbox; the inner event loop is covered by the visual smoke test.

(local tui-test (require :fen.testing.tui))
(tui-test.install-termbox-stub!)
(tui-test.install-markdown-stub!)

(local select (require :fen.extensions.tui.select))

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

(describe "select.visible-window"
  (fn []
    (it "keeps the cursor visible in long lists"
      (fn []
        (let [s (make [{:label "1"} {:label "2"} {:label "3"} {:label "4"} {:label "5"}])]
          (set s.cursor 5)
          (let [(first count total) (select.visible-window s 3)]
            (assert.are.equal 3 first)
            (assert.are.equal 3 count)
            (assert.are.equal 5 total)))))

    (it "uses a one-row no-match window for empty filtered results"
      (fn []
        (let [s (make [{:label "alpha"}])]
          (set s.filter-text "z")
          (let [(first count total) (select.visible-window s 12)]
            (assert.are.equal 1 first)
            (assert.are.equal 1 count)
            (assert.are.equal 0 total)))))))

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
