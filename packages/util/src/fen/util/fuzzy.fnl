;; Case-insensitive ordered fuzzy match; scores prefer substrings, runs, boundaries, earlier matches.

(local M {})

(fn lower [s]
  (string.lower (tostring (or s ""))))

(fn boundary? [s i]
  (or (= i 1) (let [prev (string.sub s (- i 1) (- i 1))]
                (or (= prev " ") (= prev "-") (= prev "_") (= prev "/")
                    (= prev ":") (= prev ".")))))

;; @doc fen.util.fuzzy.score
;; kind: function
;; signature: (score query candidate) -> number|nil
;; summary: Return a fuzzy-match score when all query characters appear in order within candidate; higher is better.
;; tags: util fuzzy search
(fn M.score [query candidate]
  (let [q (lower query)
        c (lower candidate)
        qn (length q)
        cn (length c)]
    (if (= qn 0)
        0
        (let [substring? (string.find c q 1 true)
              positions []]
          (var ci 1)
          (var qi 1)
          (while (and (<= qi qn) (<= ci cn))
            (let [qc (string.sub q qi qi)
                  cc (string.sub c ci ci)]
              (if (= qc cc)
                  (do
                    (table.insert positions ci)
                    (set qi (+ qi 1))
                    (set ci (+ ci 1)))
                  (set ci (+ ci 1)))))
          (when (> qi qn)
            (var score 0)
            (var last nil)
            (each [idx pos (ipairs positions)]
              (set score (+ score 10))
              (when (= pos idx)
                (set score (+ score 3)))
              (when (boundary? c pos)
                (set score (+ score 4)))
              (when last
                (if (= pos (+ last 1))
                    (set score (+ score 6))
                    (set score (- score (math.min 8 (- pos last 1))))))
              (set last pos))
            (when substring?
              (set score (+ score 20)))
            (set score (- score (math.min 20 (or (. positions 1) 1))))
            (set score
                 (- score (math.min 20 (- (or last cn) (. positions 1) -1 qn))))
            score)))))

;; @doc fen.util.fuzzy.edit-distance
;; kind: function
;; signature: (edit-distance a b) -> number
;; summary: Return case-insensitive edit distance between two values rendered as strings, counting one adjacent transposition as one typo.
;; tags: util fuzzy typo
(fn M.edit-distance [a b]
  (let [a (lower a)
        b (lower b)
        an (length a)
        bn (length b)]
    (if (= an 0)
        bn
        (= bn 0)
        an
        (do
          (var prev {})
          (var prevprev nil)
          (for [j 0 bn]
            (tset prev j j))
          (for [i 1 an]
            (let [curr {0 i}]
              (for [j 1 bn]
                (let [cost (if (= (string.sub a i i) (string.sub b j j)) 0 1)
                      deletion (+ (. prev j) 1)
                      insertion (+ (. curr (- j 1)) 1)
                      substitution (+ (. prev (- j 1)) cost)
                      transposition (and prevprev (> i 1) (> j 1)
                                         (= (string.sub a i i)
                                            (string.sub b (- j 1) (- j 1)))
                                         (= (string.sub a (- i 1) (- i 1))
                                            (string.sub b j j))
                                         (+ (. prevprev (- j 2)) 1))]
                  (tset curr j
                        (if transposition
                            (math.min deletion insertion substitution
                                      transposition)
                            (math.min deletion insertion substitution)))))
              (set prevprev prev)
              (set prev curr)))
          (. prev bn)))))

(fn best-score [query item text-fn]
  (let [texts (text-fn item)]
    (var best nil)
    (if (= (type texts) :table)
        (each [_ text (ipairs texts)]
          (let [s (M.score query text)]
            (when (and s (or (not best) (> s best)))
              (set best s))))
        (set best (M.score query texts)))
    best))

;; @doc fen.util.fuzzy.ranked
;; kind: function
;; signature: (ranked query items text-fn ?opts) -> [item]
;; summary: Return fuzzy matches sorted by descending score while preserving input order for equal scores; ?opts.min-score drops weak matches.
;; tags: util fuzzy search rank
(fn M.ranked [query items text-fn ?opts]
  (if (= (lower query) "")
      (let [out []]
        (each [_ item (ipairs (or items []))]
          (table.insert out item))
        out)
      (let [scored []]
        (each [i item (ipairs (or items []))]
          (let [s (best-score query item text-fn)
                min-score (?. ?opts :min-score)]
            (when (and s (or (not min-score) (>= s min-score)))
              (table.insert scored {:item item :score s :index i}))))
        (table.sort scored
                    (fn [a b]
                      (if (= a.score b.score)
                          (< a.index b.index)
                          (> a.score b.score))))
        (let [out []]
          (each [_ entry (ipairs scored)]
            (table.insert out entry.item))
          out))))

M
