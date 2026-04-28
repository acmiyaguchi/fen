;; Lightweight Markdown renderer for the TUI.
;;
;; Block parsing is intentionally small and line-oriented. Inline rendering is
;; segment-aware for bold/italic only, so the TUI can paint styled spans without
;; pulling in a full Markdown parser.

(local tb (require :termbox2))

(local M {})

(local C
  {:assistant tb.GREEN
   ;; Keep Markdown structure visually distinct from chat roles:
   ;; user text is cyan/bold in the TUI, so headings should not be cyan, and
   ;; list bodies should stay assistant-colored instead of making whole list
   ;; rows look like user turns.
   :heading (bor (or tb.MAGENTA tb.YELLOW) tb.BOLD)
   :heading-h1 (bor (or tb.MAGENTA tb.YELLOW) tb.BOLD tb.UNDERLINE)
   :bold (bor tb.GREEN tb.BOLD)
   :italic (bor tb.GREEN tb.ITALIC)
   :code (bor tb.YELLOW tb.BOLD)
   :link (bor tb.CYAN tb.UNDERLINE)
   :strike (bor tb.GREEN (or tb.STRIKEOUT tb.DIM))
   :dim (bor tb.WHITE tb.DIM)
   :blockquote (bor tb.WHITE tb.DIM tb.ITALIC)
   :list-marker (bor tb.WHITE tb.BOLD)
   :table-border (bor tb.WHITE tb.DIM)
   :table-header (bor tb.YELLOW tb.BOLD)
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

(fn utf8-step [s i]
  (let [b (string.byte s i)]
    (if (not b) 1
        (< b 128) 1
        (< b 224) 2
        (< b 240) 3
        4)))

(fn display-len [s]
  "Approximate terminal width: count UTF-8 codepoints as one cell."
  (let [text (or s "")]
    (var i 1)
    (var n 0)
    (while (<= i (length text))
      (set n (+ n 1))
      (set i (+ i (utf8-step text i))))
    n))

(fn take-cols [s cols]
  "Return a UTF-8-safe prefix with at most cols codepoints."
  (let [text (or s "")
        limit (math.max 0 (or cols 0))]
    (var i 1)
    (var used 0)
    (var end 0)
    (while (and (<= i (length text)) (< used limit))
      (let [step (utf8-step text i)
            next-i (+ i step)]
        (when (<= (- next-i 1) (length text))
          (set end (- next-i 1))
          (set used (+ used 1)))
        (set i next-i)))
    (string.sub text 1 end)))

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

(fn split-table-row [line]
  "Return trimmed table cells, or nil if the line is not table-like."
  (let [raw (trim line)]
    (var t raw)
    (when (string.find t "|" 1 true)
      (when (= (string.sub t 1 1) "|")
        (set t (string.sub t 2)))
      (when (= (string.sub t (length t) (length t)) "|")
        (set t (string.sub t 1 (- (length t) 1))))
      (let [cells []]
        (var start 1)
        (var done? false)
        (while (not done?)
          (let [j (string.find t "|" start true)]
            (if j
                (do (table.insert cells (trim (string.sub t start (- j 1))))
                    (set start (+ j 1)))
                (do (table.insert cells (trim (string.sub t start)))
                    (set done? true)))))
        (when (>= (length cells) 2) cells)))))

(fn table-separator? [cells]
  (and cells
       (let []
         (var ok? true)
         (each [_ c (ipairs cells)]
           (when (not (string.match c "^:?-+:?$"))
             (set ok? false)))
         ok?)))

(fn table-start? [lines i]
  (let [header (split-table-row (. lines i))
        sep (split-table-row (. lines (+ i 1)))]
    (and header (table-separator? sep) header)))

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
            table-header (and (< i n) (table-start? lines i))
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

            table-header
            (let [rows []]
              ;; Skip header + separator.
              (set i (+ i 2))
              (while (and (<= i n) (split-table-row (. lines i)))
                (table.insert rows (split-table-row (. lines i)))
                (set i (+ i 1)))
              (table.insert blocks {:kind :table :headers table-header :rows rows}))

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

;; -------------------------------------------------------------------------
;; Inline segments + wrapping
;; -------------------------------------------------------------------------

(fn append-seg [segments text attr]
  (when (> (length (or text "")) 0)
    (let [last (. segments (length segments))]
      (if (and last (= last.attr attr))
          (set last.text (.. last.text text))
          (table.insert segments {:text text :attr attr})))))

(fn parse-inline [s base-attr]
  "Parse the inline constructs called out in issue #11: bold, italic,
   inline code, links (with URL in dim parens), and strikethrough. This is
   intentionally non-recursive and conservative; unmatched markers are emitted
   literally."
  (let [text (or s "")
        base (or base-attr C.assistant)
        segments []]
    (var pos 1)
    (while (<= pos (length text))
      (let [two (string.sub text pos (+ pos 1))
            ch (string.sub text pos pos)]
        (if (= ch "`")
            (let [close (string.find text "`" (+ pos 1) true)]
              (if close
                  (do (append-seg segments
                                  (string.sub text (+ pos 1) (- close 1))
                                  C.code)
                      (set pos (+ close 1)))
                  (do (append-seg segments ch base)
                      (set pos (+ pos 1)))))

            (= ch "[")
            (let [bracket-close (string.find text "]" (+ pos 1) true)]
              (if (and bracket-close
                       (= (string.sub text (+ bracket-close 1) (+ bracket-close 1)) "("))
                  (let [paren-close (string.find text ")" (+ bracket-close 2) true)]
                    (if paren-close
                        (let [label (string.sub text (+ pos 1) (- bracket-close 1))
                              href (string.sub text (+ bracket-close 2) (- paren-close 1))]
                          (append-seg segments label C.link)
                          (when (> (length href) 0)
                            (append-seg segments (.. " (" href ")") C.dim))
                          (set pos (+ paren-close 1)))
                        (do (append-seg segments ch base)
                            (set pos (+ pos 1)))))
                  (do (append-seg segments ch base)
                      (set pos (+ pos 1)))))

            (= two "~~")
            (let [close (string.find text "~~" (+ pos 2) true)]
              (if close
                  (do (append-seg segments
                                  (string.sub text (+ pos 2) (- close 1))
                                  C.strike)
                      (set pos (+ close 2)))
                  (do (append-seg segments ch base)
                      (set pos (+ pos 1)))))

            (or (= two "**") (= two "__"))
            (let [close (string.find text two (+ pos 2) true)]
              (if close
                  (do (append-seg segments
                                  (string.sub text (+ pos 2) (- close 1))
                                  (bor base tb.BOLD))
                      (set pos (+ close 2)))
                  (do (append-seg segments ch base)
                      (set pos (+ pos 1)))))

            (or (= ch "*") (= ch "_"))
            (let [close (string.find text ch (+ pos 1) true)]
              (if (and close (> close (+ pos 1)))
                  (do (append-seg segments
                                  (string.sub text (+ pos 1) (- close 1))
                                  (bor base tb.ITALIC))
                      (set pos (+ close 1)))
                  (do (append-seg segments ch base)
                      (set pos (+ pos 1)))))

            (do (append-seg segments ch base)
                (set pos (+ pos 1))))))
    (when (= (length segments) 0)
      (table.insert segments {:text "" :attr base}))
    segments))

(fn row-text [segments]
  (let [parts []]
    (each [_ seg (ipairs segments)]
      (table.insert parts (or seg.text "")))
    (table.concat parts "")))

(fn row-from-segments [segments fallback-attr]
  (let [segs (if (> (length segments) 0)
                 segments
                 [{:text "" :attr (or fallback-attr C.assistant)}])]
    {:segments segs
     :text (row-text segs)
     :attr (or (?. segs 1 :attr) fallback-attr C.assistant)}))

(fn append-char-seg [segments ch attr]
  (let [last (. segments (length segments))]
    (if (and last (= last.attr attr))
        (set last.text (.. last.text ch))
        (table.insert segments {:text ch :attr attr}))))

(fn wrap-segments [segments width fallback-attr]
  "Wrap segment list to rows while preserving per-span attrs."
  (let [w (math.max 1 (or width 80))
        rows []]
    (var cur [])
    (var col 0)
    (fn flush []
      (table.insert rows (row-from-segments cur fallback-attr))
      (set cur [])
      (set col 0))
    (each [_ seg (ipairs segments)]
      (let [text (or seg.text "")
            attr (or seg.attr fallback-attr C.assistant)]
        (var i 1)
        (while (<= i (length text))
          (when (>= col w) (flush))
          (let [step (utf8-step text i)
                ch (string.sub text i (+ i step -1))]
            (append-char-seg cur ch attr)
            (set col (+ col 1))
            (set i (+ i step))))))
    (when (or (> (length cur) 0) (= (length rows) 0))
      (flush))
    rows))

(fn push-inline-wrapped [rows text attr width]
  (each [_ row (ipairs (wrap-segments (parse-inline text attr) width attr))]
    (table.insert rows row)))

(fn push-list-wrapped [rows prefix text width]
  "Render list marker with structure color, but list body as assistant text."
  (let [segments [{:text prefix :attr C.list-marker}]]
    (each [_ seg (ipairs (parse-inline (or text "") C.assistant))]
      (table.insert segments seg))
    (each [_ row (ipairs (wrap-segments segments width C.assistant))]
      (table.insert rows row))))

(fn wrap-line [line width]
  "Hard-wrap a single plain line by UTF-8 codepoints."
  (let [w (math.max 1 (or width 80))
        s (or line "")
        out []]
    (if (= s "")
        (table.insert out "")
        (do (var i 1)
            (var col 0)
            (var buf "")
            (while (<= i (length s))
              (when (>= col w)
                (table.insert out buf)
                (set buf "")
                (set col 0))
              (let [step (utf8-step s i)
                    ch (string.sub s i (+ i step -1))]
                (set buf (.. buf ch))
                (set col (+ col 1))
                (set i (+ i step))))
            (when (or (> (length buf) 0) (= (length out) 0))
              (table.insert out buf))))
    out))

(fn push-wrapped [rows text attr width]
  (each [_ chunk (ipairs (wrap-line text width))]
    (table.insert rows {:text chunk :attr attr})))

;; -------------------------------------------------------------------------
;; Table rendering
;; -------------------------------------------------------------------------

(fn table-col-count [headers rows]
  (let []
    (var n (length (or headers [])))
    (each [_ row (ipairs (or rows []))]
      (when (> (length row) n) (set n (length row))))
    n))

(fn table-cell [row idx]
  (or (. (or row []) idx) ""))

(fn table-total-width [widths]
  (let [n (length widths)]
    (if (= n 0) 0
        (do (var total 1)
            (each [_ w (ipairs widths)]
              (set total (+ total w 3)))
            total))))

(fn shrink-widths! [widths max-width]
  (let [minw 3]
    (while (> (table-total-width widths) max-width)
      (var max-i nil)
      (var max-v minw)
      (each [i w (ipairs widths)]
        (when (> w max-v)
          (set max-v w)
          (set max-i i)))
      (if max-i
          (tset widths max-i (- (. widths max-i) 1))
          ;; Cannot shrink further.
          (lua "break")))))

(fn fit-cell [s width]
  (let [w (math.max 1 width)
        text (or s "")]
    (if (<= (display-len text) w)
        (.. text (string.rep " " (- w (display-len text))))
        (if (= w 1)
            "…"
            (.. (take-cols text (- w 1)) "…")))))

(fn table-border [left mid right fill widths]
  (let [parts [left]]
    (each [i w (ipairs widths)]
      (table.insert parts (string.rep fill (+ w 2)))
      (table.insert parts (if (= i (length widths)) right mid)))
    (table.concat parts "")))

(fn table-row-line [cells widths]
  (let [parts ["│"]]
    (each [i w (ipairs widths)]
      (table.insert parts " ")
      (table.insert parts (fit-cell (table-cell cells i) w))
      (table.insert parts " │"))
    (table.concat parts "")))

(fn render-table [block width]
  (let [w (math.max 1 (or width 80))
        headers (or block.headers [])
        rows (or block.rows [])
        cols (table-col-count headers rows)
        widths []
        out []]
    (for [i 1 cols]
      (var cw (display-len (table-cell headers i)))
      (each [_ row (ipairs rows)]
        (set cw (math.max cw (display-len (table-cell row i)))))
      (table.insert widths (math.max 3 cw)))
    (shrink-widths! widths w)
    (table.insert out {:text (table-border "┌" "┬" "┐" "─" widths)
                       :attr C.table-border})
    (table.insert out {:text (table-row-line headers widths)
                       :attr C.table-header})
    (table.insert out {:text (table-border "├" "┼" "┤" "─" widths)
                       :attr C.table-border})
    (each [_ row (ipairs rows)]
      (table.insert out {:text (table-row-line row widths)
                         :attr C.assistant}))
    (table.insert out {:text (table-border "└" "┴" "┘" "─" widths)
                       :attr C.table-border})
    out))

;; -------------------------------------------------------------------------
;; Block rendering
;; -------------------------------------------------------------------------

(fn render-block [block width]
  "Render one parsed block to TUI rows. Rows may be flat {:text :attr} or
   segment-aware {:segments [{:text :attr} ...] :text :attr}."
  (let [w (math.max 1 (or width 80))
        rows []]
    (if (= block.kind :heading)
        (push-inline-wrapped rows (or block.text "")
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
          (push-list-wrapped rows prefix (or block.text "") w))

        (= block.kind :ordered)
        (let [indent-level (math.floor (/ (or block.indent 0) 2))
              prefix (.. (string.rep "  " indent-level)
                         (tostring (or block.number 1)) ". ")]
          (push-list-wrapped rows prefix (or block.text "") w))

        (= block.kind :blockquote)
        (each [_ l (ipairs (split-lines (or block.text "")))]
          (push-inline-wrapped rows (.. "│ " l) C.blockquote w))

        (= block.kind :table)
        (each [_ row (ipairs (render-table block w))]
          (table.insert rows row))

        (= block.kind :hr)
        (table.insert rows {:text (string.rep "─" w) :attr C.hr})

        (= block.kind :blank)
        (table.insert rows {:text "" :attr C.normal})

        ;; paragraph / unknown fallback
        (push-inline-wrapped rows (or block.text "") C.assistant w))
    rows))

(fn render-text [s width]
  "Parse and render Markdown text to TUI rows."
  (let [out []]
    (each [_ block (ipairs (parse-blocks s))]
      (each [_ row (ipairs (render-block block width))]
        (table.insert out row)))
    out))

(fn M.parse [s] (parse-blocks s))
(fn M.parse-inline [s attr] (parse-inline s attr))
(fn M.render-block [block width] (render-block block width))
(fn M.render-text [s width] (render-text s width))
(fn M.render [s width] (render-text s width))
(fn M.display-len [s] (display-len s))

M
