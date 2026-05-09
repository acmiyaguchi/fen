;; Small pure-Fennel fuzzy matcher.
;;
;; Public surface follows the planned fen.util.search.bitap shape. The matcher
;; is intentionally allocation-light and dependency-free; score is the primary
;; consumer API for docs/palette filtering.

(local M {})

(fn clamp [x lo hi]
  (math.max lo (math.min hi x)))

(fn lower-if [s enabled?]
  (if enabled? (string.lower s) s))

(fn default-max-errors [n]
  (if (<= n 1)
      0
      (clamp (math.floor (/ n 4)) 1 3)))

(fn M.compile [pattern ?opts]
  (let [opts (or ?opts {})
        case-fold? (if (= opts.case-fold? nil) true opts.case-fold?)
        pat (lower-if (tostring (or pattern "")) case-fold?)
        max-errors (or opts.max-errors (default-max-errors (length pat)))]
    {:pattern pat
     :raw-pattern (tostring (or pattern ""))
     :len (length pat)
     :case-fold? case-fold?
     :max-errors max-errors}))

(fn char-at [s i]
  (string.sub s i i))

(fn word-boundary? [text pos]
  (or (<= pos 1)
      (not (string.match (string.sub text (- pos 1) (- pos 1)) "[%w_]"))))

(fn exact-match [compiled text]
  (let [pos (string.find text compiled.pattern 1 true)]
    (when pos
      {:matched? true
       :start pos
       :end (+ pos compiled.len -1)
       :errors 0
       :exact? true})))

(fn approx-match [compiled text]
  (let [m compiled.len
        n (length text)
        max-errors compiled.max-errors]
    (when (> m 0)
      (let []
        (var prev [])
        (for [j 0 n]
          (tset prev (+ j 1) 0))
        (var best nil)
        (for [i 1 m]
          (let [curr []]
            (tset curr 1 i)
            (for [j 1 n]
              (let [cost (if (= (char-at compiled.pattern i) (char-at text j)) 0 1)
                    deletion (+ (. prev (+ j 1)) 1)
                    insertion (+ (. curr j) 1)
                    substitution (+ (. prev j) cost)]
                (tset curr (+ j 1) (math.min deletion insertion substitution))))
            (set prev curr)))
        (for [j 1 n]
          (let [errors (. prev (+ j 1))]
            (when (and (<= errors max-errors)
                       (or (not best)
                           (< errors best.errors)
                           (and (= errors best.errors) (< j best.end))))
              ;; Approximate start is enough for scoring; exact highlight ranges are
              ;; intentionally not part of v1.
              (set best {:matched? true
                         :start (math.max 1 (- j m -1))
                         :end j
                         :errors errors}))))
        best))))

(fn subsequence-score [compiled text]
  (let [m compiled.len
        n (length text)]
    (when (> m 0)
      (var pi 1)
      (var start nil)
      (var last 0)
      (var gaps 0)
      (var run 0)
      (var best-run 0)
      (for [i 1 n]
        (when (and (<= pi m) (= (char-at compiled.pattern pi) (char-at text i)))
          (when (not start) (set start i))
          (when (> last 0)
            (set gaps (+ gaps (- i last 1))))
          (if (= i (+ last 1))
              (set run (+ run 1))
              (set run 1))
          (set best-run (math.max best-run run))
          (set last i)
          (set pi (+ pi 1))))
      (when (> pi m)
        (+ 120
           (* best-run 4)
           (if (word-boundary? text start) 20 0)
           (- (* gaps 2))
           (- start))))))

(fn M.match [compiled raw-text ?opts]
  (let [opts (or ?opts {})
        c (if compiled.pattern compiled (M.compile compiled opts))
        text (lower-if (tostring (or raw-text "")) c.case-fold?)]
    (if (= c.len 0)
        {:matched? true :start 1 :end 0 :errors 0 :exact? true}
        (or (exact-match c text)
            (approx-match c text)))))

(fn M.score [compiled raw-text]
  (let [c (if compiled.pattern compiled (M.compile compiled))
        text (lower-if (tostring (or raw-text "")) c.case-fold?)]
    (when (> c.len 0)
      (let [m (M.match c text)]
        (if m
            (+ 1000
               (- (* m.errors 100))
               (if m.exact? 100 0)
               (if (word-boundary? text m.start) 30 0)
               (- (or m.start 1)))
            (subsequence-score c text))))))

M
