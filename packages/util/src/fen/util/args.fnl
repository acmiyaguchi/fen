;; Small slash-command argument parsing helpers.
;;
;; These helpers intentionally preserve the simple whitespace-delimited parsing
;; used by first-party commands. They are not shell parsers.

(local M {})

;; @doc fen.util.args.nth-arg
;; kind: function
;; signature: (nth-arg args n) -> string|nil
;; summary: Extract the nth whitespace-delimited argument from a slash-command argument string.
;; tags: util args commands
(fn M.nth-arg [args n]
  (when (and (= (type n) :number) (>= n 1))
    (let [pat (.. (string.rep "%S+%s+" (- (math.floor n) 1)) "(%S+)")]
      (string.match (or args "") pat))))

;; @doc fen.util.args.first-arg
;; kind: function
;; signature: (first-arg args) -> string|nil
;; summary: Extract the first whitespace-delimited argument from a slash-command argument string.
;; tags: util args commands
(fn M.first-arg [args]
  (M.nth-arg args 1))

;; @doc fen.util.args.rest-args
;; kind: function
;; signature: (rest-args args) -> string
;; summary: Return everything after the first whitespace-delimited argument, trimmed; nil and missing rest become "".
;; tags: util args commands
(fn M.rest-args [args]
  (or (string.match (or args "") "^%s*%S+%s*(.-)%s*$") ""))

;; @doc fen.util.args.rest-after-first
;; kind: function
;; signature: (rest-after-first args) -> string|nil
;; summary: Return everything after the first argument when at least one separating space exists.
;; tags: util args commands
(fn M.rest-after-first [args]
  (string.match (or args "") "^%S+%s+(.+)$"))

M
