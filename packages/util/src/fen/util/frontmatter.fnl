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
                    (let [(k v) (string.match line "^([%w][%w%-_]*)%s*:%s*(.*)$")]
                      (when k
                        (tset fields k (strip-quotes (trim v)))))
                    (set pos next-pos)))))
        (if header? (values fields body) nil))))

;; @doc fen.util.frontmatter.parse-file
;; kind: function
;; signature: (parse-file path) -> (values fields body) | nil
;; summary: Read `path` and parse its frontmatter. Returns nil when the file
;;   cannot be opened or has no leading `---` delimiter.
;; tags: util frontmatter parsing
(fn M.parse-file [path]
  (let [f (io.open path :r)]
    (if (not f)
        nil
        (let [text (f:read :*a)]
          (f:close)
          (M.parse (or text ""))))))

M
