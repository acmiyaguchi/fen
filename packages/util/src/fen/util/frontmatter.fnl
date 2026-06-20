;; Neutral YAML-ish frontmatter parser shared by skills and agents.
;; Returns (values fields body): a flat string->string field map plus the
;; document body that follows the closing `---`. Field-specific validation
;; (required keys, name fallbacks, boolean coercion) is left to callers.
(local trim (. (require :fen.util.text) :trim))

(local M {})

(fn strip-quotes [s]
  (let [m (or (string.match s "^\"(.*)\"$")
              (string.match s "^'(.*)'$"))]
    (or m s)))

(fn parse-field! [fields line]
  "Parse a single `key: value` frontmatter line into FIELDS (quote-stripped and
   trimmed). Non-matching lines are ignored. Shared by the string and file
   parsers so the field grammar lives in one place."
  (let [(k v) (string.match line "^([%w][%w%-_]*)%s*:%s*(.*)$")]
    (when k (tset fields k (strip-quotes (trim v))))))

;; @doc fen.util.frontmatter.parse
;; kind: function
;; signature: (parse text) -> (values fields body) | nil
;; summary: Parse leading `---` frontmatter out of a string. Returns nil when
;;   the text does not start with a `---` delimiter line. `fields` is a
;;   string->string map (values quote-stripped and trimmed); `body` is the text
;;   after the closing `---` ("" when no closing delimiter is found).
;; tags: util frontmatter parsing
(fn M.parse [text]
  (if (or (not text) (= text ""))
      nil
      (let [fields {}]
        (var pos 1)
        (var first? true)
        (var header? false)
        (var done? false)
        (var body "")
        (var lines-read 0)
        ;; First line must be the opening `---`; then scan <=64 lines for the
        ;; closing `---`. Everything after the closing delimiter is the body.
        (while (and (not done?) (<= pos (length text)) (< lines-read 65))
          (let [nl (string.find text "\n" pos true)
                line (if nl (string.sub text pos (- nl 1)) (string.sub text pos))
                next-pos (if nl (+ nl 1) (+ (length text) 1))]
            (if first?
                (do (set first? false)
                    (if (= line "---")
                        (set header? true)
                        (set done? true))
                    (set pos next-pos))
                (= line "---")
                (do (set body (string.sub text next-pos))
                    (set done? true))
                (do (set lines-read (+ lines-read 1))
                    (parse-field! fields line)
                    (set pos next-pos)))))
        (if header? (values fields body) nil))))

;; @doc fen.util.frontmatter.parse-file
;; kind: function
;; signature: (parse-file path ?with-body) -> (values fields body) | (values nil reason err)
;; summary: Read `path` and parse its frontmatter line-by-line, stopping at the
;;   closing `---` so a large body is not slurped when only metadata is needed.
;;   The body is read (everything after the closing delimiter) only when
;;   `?with-body` is truthy; otherwise `body` is "". On failure returns
;;   `(values nil reason)` where reason is `:unreadable` (with the io error as a
;;   third value) or `:no-frontmatter`, letting callers warn precisely.
;; tags: util frontmatter parsing
(fn M.parse-file [path ?with-body]
  (let [(f err) (io.open path :r)]
    (if (not f)
        (values nil :unreadable err)
        (let [first (f:read :*l)]
          (if (not= first "---")
              (do (f:close) (values nil :no-frontmatter))
              (let [fields {}]
                ;; Scan <=64 field lines for the closing `---`; everything after
                ;; it is the body (read only when the caller asks for it).
                (var closed? false)
                (var lines-read 0)
                (while (and (not closed?) (< lines-read 65))
                  (let [line (f:read :*l)]
                    (if (or (not line) (= line "---"))
                        (set closed? true)
                        (do (set lines-read (+ lines-read 1))
                            (parse-field! fields line)))))
                (let [body (if ?with-body (or (f:read :*a) "") "")]
                  (f:close)
                  (values fields body))))))))

M
