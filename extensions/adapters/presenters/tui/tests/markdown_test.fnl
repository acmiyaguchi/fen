;; Tests for tui.markdown — issue #11 v1 block-level renderer.

;; Mock termbox2 with fake constants so the module can load in test env.
(tset package.loaded "termbox2"
  {:CYAN 6 :GREEN 2 :YELLOW 3 :RED 1 :WHITE 7 :BLUE 4
   :BOLD 2097152 :DIM 8388608 :REVERSE 524288 :DEFAULT 0
   :UNDERLINE 33554432 :ITALIC 16777216})

(local md (require :fen.extensions.tui.markdown))

(describe "tui.markdown.parse"
  (fn []
    (it "parses a simple paragraph"
      (fn []
        (let [blocks (md.parse "Hello, world!")]
          (assert.are.same 1 (length blocks))
          (assert.are.same "paragraph" (. blocks 1 :kind))
          (assert.are.same "Hello, world!" (. blocks 1 :text)))))

    (it "preserves explicit paragraph line breaks"
      (fn []
        (let [blocks (md.parse "one\ntwo")]
          (assert.are.same 2 (length blocks))
          (assert.are.same "one" (. blocks 1 :text))
          (assert.are.same "two" (. blocks 2 :text)))))

    (it "parses an empty string as one empty paragraph"
      (fn []
        (let [blocks (md.parse "")]
          (assert.are.same 1 (length blocks))
          (assert.are.same "paragraph" (. blocks 1 :kind)))))

    (it "parses headings and strips trailing hashes"
      (fn []
        (let [blocks (md.parse "# Title ##")]
          (assert.are.same 1 (length blocks))
          (assert.are.same "heading" (. blocks 1 :kind))
          (assert.are.same 1 (. blocks 1 :level))
          (assert.are.same "Title" (. blocks 1 :text)))))

    (it "parses a fenced code block"
      (fn []
        (let [blocks (md.parse "```fennel\n(fn hello [] :world)\n```")]
          (assert.are.same 1 (length blocks))
          (assert.are.same "code-block" (. blocks 1 :kind))
          (assert.are.same "fennel" (. blocks 1 :language))
          (assert.are.same "(fn hello [] :world)" (. blocks 1 :text)))))

    (it "parses horizontal rules"
      (fn []
        (each [_ rule (ipairs ["---" "***" "___"])]
          (let [blocks (md.parse rule)]
            (assert.are.same 1 (length blocks))
            (assert.are.same "hr" (. blocks 1 :kind))))))

    (it "parses grouped blockquotes"
      (fn []
        (let [blocks (md.parse "> first\n> second")]
          (assert.are.same 1 (length blocks))
          (assert.are.same "blockquote" (. blocks 1 :kind))
          (assert.are.same "first\nsecond" (. blocks 1 :text)))))

    (it "parses unordered and ordered list items"
      (fn []
        (let [blocks (md.parse "- first\n2. second")]
          (assert.are.same 2 (length blocks))
          (assert.are.same "bullet" (. blocks 1 :kind))
          (assert.are.same "first" (. blocks 1 :text))
          (assert.are.same "ordered" (. blocks 2 :kind))
          (assert.are.same 2 (. blocks 2 :number)))))

    (it "parses multiple blocks and keeps blank lines"
      (fn []
        (let [blocks (md.parse "# Title\n\nParagraph text\n\n---")]
          (assert.are.same 5 (length blocks))
          (assert.are.same "heading" (. blocks 1 :kind))
          (assert.are.same "blank" (. blocks 2 :kind))
          (assert.are.same "paragraph" (. blocks 3 :kind))
          (assert.are.same "blank" (. blocks 4 :kind))
          (assert.are.same "hr" (. blocks 5 :kind)))))

    (it "parses pipe tables"
      (fn []
        (let [blocks (md.parse "| A | B |\n| --- | --- |\n| 1 | 2 |")]
          (assert.are.same 1 (length blocks))
          (assert.are.same "table" (. blocks 1 :kind))
          (assert.are.same "A" (?. blocks 1 :headers 1))
          (assert.are.same "2" (?. blocks 1 :rows 1 2)))))))

(describe "tui.markdown.render-text"
  (fn []
    (it "renders a heading"
      (fn []
        (let [lines (md.render-text "# Title" 80)]
          (assert.are.same 1 (length lines))
          (assert.are.same "Title" (. lines 1 :text)))))

    (it "renders a horizontal rule to the requested width"
      (fn []
        (let [lines (md.render-text "---" 10)]
          (assert.are.same 1 (length lines))
          (assert.are.same "──────────" (. lines 1 :text)))))

    (it "hard-wraps paragraphs"
      (fn []
        (let [lines (md.render-text "abcdefghij" 4)]
          (assert.are.same 3 (length lines))
          (assert.are.same "abcd" (. lines 1 :text))
          (assert.are.same "efgh" (. lines 2 :text))
          (assert.are.same "ij" (. lines 3 :text)))))

    (it "renders inline bold italic code links and strikethrough as segments"
      (fn []
        (let [lines (md.render-text "**bold** *it* `code` [x](u) ~~gone~~" 80)
              line (. lines 1)]
          (assert.are.same "bold it code x (u) gone" line.text)
          (assert.are.truthy line.segments)
          (assert.are.truthy (> (length line.segments) 1)))))

    (it "preserves blank lines in rendered text"
      (fn []
        (let [lines (md.render-text "one\n\ntwo" 80)]
          (assert.are.same 3 (length lines))
          (assert.are.same "one" (. lines 1 :text))
          (assert.are.same "" (. lines 2 :text))
          (assert.are.same "two" (. lines 3 :text)))))

    (it "renders a blockquote prefix"
      (fn []
        (let [lines (md.render-text "> Quoted text" 80)]
          (assert.are.same 1 (length lines))
          (assert.are.truthy (string.find (. lines 1 :text) "│ Quoted" 1 true)))))

    (it "renders bullet and numbered markers"
      (fn []
        (let [lines (md.render-text "- item one\n3. item three" 80)]
          (assert.are.same "• item one" (. lines 1 :text))
          (assert.are.same "3. item three" (. lines 2 :text)))))

    (it "renders fenced code with borders and indentation"
      (fn []
        (let [lines (md.render-text "```lua\nprint('x')\n```" 12)]
          (assert.are.same 3 (length lines))
          (assert.are.same "── lua ─────" (. lines 1 :text))
          (assert.are.same "  print('x')" (. lines 2 :text))
          (assert.are.same "────────────" (. lines 3 :text)))))

    (it "renders pipe tables as a grid"
      (fn []
        (let [lines (md.render-text "| A | B |\n| --- | --- |\n| 1 | 2 |" 40)]
          (assert.are.same 5 (length lines))
          (assert.are.same "┌─────┬─────┐" (. lines 1 :text))
          (assert.are.same "│ A   │ B   │" (. lines 2 :text))
          (assert.are.same "│ 1   │ 2   │" (. lines 4 :text)))))))
