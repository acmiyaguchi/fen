;; Waiver parsing for scripts/lint:  ;; lint-allow <rule>: <reason>
;; A waiver covers a finding on its own line (as a trailing comment) or on the
;; next line (as a comment-only line), never two findings at once.

(local M {})

(local PATTERN "^;+%s*lint%-allow%s+([%w/_%-]+):?%s*(.-)%s*$")

(fn comment-part [line]
  "The `;` comment of a line, ignoring `;` inside string literals, or nil."
  (var in-string? false)
  (var escaped? false)
  (var found nil)
  (for [i 1 (length line) &until found]
    (let [ch (string.sub line i i)]
      (if escaped? (set escaped? false)
          (and in-string? (= ch "\\")) (set escaped? true)
          (= ch "\"") (set in-string? (not in-string?))
          (and (not in-string?) (= ch ";")) (set found (string.sub line i)))))
  found)

(fn parse [line]
  (let [c (comment-part (or line ""))]
    (when c
      (string.match c PATTERN))))

(fn M.for-line [lines n rule]
  "Reason if a finding of `rule` on line `n` of `lines` is waived, :no-reason
   when the waiver gives none, else nil."
  (let [own (. lines n)
        above (. lines (- n 1))
        candidates [[own (parse own)]
                    (when (and above (string.match above "^%s*;"))
                      [above (parse above)])]]
    (accumulate [hit nil _ c (ipairs candidates) &until hit]
      (let [[_ r reason] c]
        (when (= r rule)
          (if (= reason "") :no-reason reason))))))

M
