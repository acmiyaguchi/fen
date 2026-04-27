;; Lightweight block-level Markdown renderer for the TUI.
;;
;; Issue #11 v1 scope: whole-line styling only. Inline styling is deliberately
;; deferred so the rest of the TUI can keep its simple {:text :attr} row shape.

(local tb (require :termbox2))

(local M {})

(local C
  {:assistant tb.GREEN
   :heading (bor tb.YELLOW tb.BOLD)
   :heading-h1 (bor tb.YELLOW tb.BOLD tb.UNDERLINE)
   :dim (bor tb.WHITE tb.DIM)
   :blockquote (bor tb.WHITE tb.DIM tb.ITALIC)
   ;; v1 rows carry one attr, so list markers cannot be cyan while the body
   ;; stays normal without a segment-aware paint path. Color the whole list
   ;; row cyan for now so lists are visually distinct instead of plain green.
   :list (or tb.CYAN tb.GREEN)
   :normal tb.DEFAULT
   :hr (bor tb.WHITE tb.DIM)})

(fn split-lines [s]
  "Split on \n. Preserves interior blank lines; ignores a final trailing
   newline because Markdown parsing treats it as document termination."
  (let [out []
        text (or s "")]
    (when (not= text "")
      (var start 1)
      (var done? false)
      (while (not done?)
        (let [j (string.find text "\n" start true)]
          (if j
              (do (table.insert out (string.sub text start (- j 1)))
                  (set start (+ j 1)))
              (do (when (<= start (length text))
                    (table.insert out (string.sub text start)))
                  (set done? true))))))
    out))

(fn trim [s]
  (or (string.match (or s "") "^%s*(.-)%s*$") ""))

(fn starts-with-fence? [line]
  "Return (fence-char, fence-len, info) when line is a fence."
  (let [t (trim line)
        ch (string.sub t 1 1)]
    (when (or (= ch "`") (= ch "~"))
      (var n 0)
      (while (= (string.sub t (+ n 1) (+ n 1)) ch)
        (set n (+ n 1)))
      (when (>= n 3)
        (values ch n (trim (string.sub t (+ n 1))))))))

(fn closing-fence? [line fence-ch fence-len]
  (let [(ch n) (starts-with-fence? line)]
    (and (= ch fence-ch) (>= (or n 0) fence-len))))

(fn hrule? [trimmed]
  (or (string.match trimmed "^%-%-%-+$")
      (string.match trimmed "^%*%*%*+$")
      (string.match trimmed "^___+$")))

(fn strip-heading-trail [text]
  (trim (or (string.match (or text "") "^(.-)%s*#+%s*$") text "")))

(fn heading-line [line]
  (let [(hashes text) (string.match line "^(#+)%s+(.-)%s*$")]
    (when (and hashes (>= (length hashes) 1) (<= (length hashes) 6))
      (values (length hashes) (strip-heading-trail text)))))

(fn bullet-line [line]
  (let [(indent text) (string.match line "^(%s*)[-*+]%s+(.*)$")]
    (when indent
      (values (length indent) text))))

(fn ordered-line [line]
  (let [(indent num text) (string.match line "^(%s*)(%d+)%.%s+(.*)$")]
    (when indent
      (values (length indent) (tonumber num) text))))

(fn quote-line [line]
  (string.match line "^%s*>%s?(.*)$"))

(fn block-start? [line]
  (let [t (trim line)
        (fch _) (starts-with-fence? line)
        (level _) (heading-line line)
        (bindent _) (bullet-line line)
        (oindent _num _) (ordered-line line)]
    (or (= t "") fch level (hrule? t) (quote-line line) bindent oindent)))

(fn parse-blocks [s]
  "Parse Markdown text to simple block records."
  (let [lines (split-lines s)
        blocks []
        n (length lines)]
    (var i 1)
    (while (<= i n)
      (let [line (. lines i)
            t (trim line)
            (fch flen info) (starts-with-fence? line)
            (level htext) (heading-line line)
            qtext (quote-line line)
            (bindent btext) (bullet-line line)
            (oindent onum otext) (ordered-line line)]
        (if (= t "")
            (do (table.insert blocks {:kind :blank})
                (set i (+ i 1)))

            fch
            (let [code []]
              (set i (+ i 1))
              (var closed? false)
              (while (and (<= i n) (not closed?))
                (if (closing-fence? (. lines i) fch flen)
                    (do (set closed? true)
                        (set i (+ i 1)))
                    (do (table.insert code (. lines i))
                        (set i (+ i 1)))))
              (table.insert blocks {:kind :code-block
                                    :language (or info "")
                                    :lines code
                                    :text (table.concat code "\n")}))

            level
            (do (table.insert blocks {:kind :heading :level level :text htext})
                (set i (+ i 1)))

            (hrule? t)
            (do (table.insert blocks {:kind :hr})
                (set i (+ i 1)))

            qtext
            (let [parts []]
              (while (and (<= i n) (quote-line (. lines i)))
                (table.insert parts (or (quote-line (. lines i)) ""))
                (set i (+ i 1)))
              (table.insert blocks {:kind :blockquote
                                    :text (table.concat parts "\n")}))

            bindent
            (do (table.insert blocks {:kind :bullet
                                      :indent bindent
                                      :text btext})
                (set i (+ i 1)))

            oindent
            (do (table.insert blocks {:kind :ordered
                                      :indent oindent
                                      :number onum
                                      :text otext})
                (set i (+ i 1)))

            ;; Paragraph/plain text. Preserve explicit source newlines by
            ;; emitting one paragraph block per input line; chat responses rely
            ;; on line breaks for readability, and existing TUI rendering did
            ;; not collapse them.
            (do (table.insert blocks {:kind :paragraph :text line})
                (set i (+ i 1))))))
    (when (= (length blocks) 0)
      (table.insert blocks {:kind :paragraph :text ""}))
    blocks))

(fn display-len [s]
  "Approximate terminal width: count UTF-8 codepoints as one cell. Good
   enough for the box-drawing and bullet characters used by this renderer."
  (let [text (or s "")]
    (var i 1)
    (var n 0)
    (while (<= i (length text))
      (let [b (string.byte text i)
            step (if (< b 128) 1
                     (< b 224) 2
                     (< b 240) 3
                     4)]
        (set n (+ n 1))
        (set i (+ i step))))
    n))

(fn wrap-line [line width]
  "Hard-wrap a single line by bytes. Most assistant text is ASCII; generated
   Markdown chrome is kept within width with display-len before wrapping."
  (let [w (math.max 1 (or width 80))
        s (or line "")
        out []]
    (if (= s "")
        (table.insert out "")
        (do (var i 1)
            (let [n (length s)]
              (while (<= i n)
                (table.insert out (string.sub s i (+ i w -1)))
                (set i (+ i w))))))
    out))

(fn push-wrapped [rows text attr width]
  (each [_ chunk (ipairs (wrap-line text width))]
    (table.insert rows {:text chunk :attr attr})))

(fn render-block [block width]
  "Render one parsed block to flat TUI rows {:text :attr}."
  (let [w (math.max 1 (or width 80))
        rows []]
    (if (= block.kind :heading)
        (push-wrapped rows (or block.text "")
                      (if (= block.level 1) C.heading-h1 C.heading)
                      w)

        (= block.kind :code-block)
        (do (let [lang (or block.language "")
                  prefix (if (> (length lang) 0) (.. "── " lang " ") "───")]
              (table.insert rows
                            {:text (.. prefix
                                       (string.rep "─" (math.max 0 (- w (display-len prefix)))))
                             :attr C.hr}))
            (let [body-lines (or block.lines [])]
              (if (= (length body-lines) 0)
                  (push-wrapped rows "  " C.dim w)
                  (each [_ l (ipairs body-lines)]
                    (push-wrapped rows (.. "  " l) C.dim w))))
            (table.insert rows {:text (string.rep "─" w) :attr C.hr}))

        (= block.kind :bullet)
        (let [indent-level (math.floor (/ (or block.indent 0) 2))
              prefix (.. (string.rep "  " indent-level) "• ")]
          (push-wrapped rows (.. prefix (or block.text "")) C.list w))

        (= block.kind :ordered)
        (let [indent-level (math.floor (/ (or block.indent 0) 2))
              prefix (.. (string.rep "  " indent-level)
                         (tostring (or block.number 1)) ". ")]
          (push-wrapped rows (.. prefix (or block.text "")) C.list w))

        (= block.kind :blockquote)
        (each [_ l (ipairs (split-lines (or block.text "")))]
          (push-wrapped rows (.. "│ " l) C.blockquote w))

        (= block.kind :hr)
        (table.insert rows {:text (string.rep "─" w) :attr C.hr})

        (= block.kind :blank)
        (table.insert rows {:text "" :attr C.normal})

        ;; paragraph / unknown fallback
        (push-wrapped rows (or block.text "") C.assistant w))
    rows))

(fn render-text [s width]
  "Parse and render Markdown text to flat TUI rows {:text :attr}."
  (let [out []]
    (each [_ block (ipairs (parse-blocks s))]
      (each [_ row (ipairs (render-block block width))]
        (table.insert out row)))
    out))

(fn M.parse [s] (parse-blocks s))
(fn M.render-block [block width] (render-block block width))
(fn M.render-text [s width] (render-text s width))
(fn M.render [s width] (render-text s width))

M
