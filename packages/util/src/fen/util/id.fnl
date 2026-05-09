;; Small stable ID helpers.
;;
;; `uuidv7` returns UUIDv7-shaped, time-sortable IDs for local session
;; entries. Random bits come from fen.util.random; the timestamp uses os.time
;; plus a per-second counter because Lua's portable clock is second-grained.

(local random (require :fen.util.random))

(local M {})

(var last-sec nil)
(var per-sec-counter 0)

(fn bytes-to-hex [s]
  (let [parts []]
    (for [i 1 (length s)]
      (table.insert parts (string.format "%02x" (string.byte s i))))
    (table.concat parts "")))

(fn M.random-hex [n]
  "Return n random hexadecimal characters."
  (let [byte-count (math.ceil (/ n 2))
        hex (bytes-to-hex (random.bytes byte-count))]
    (string.sub hex 1 n)))

(fn timestamp-ms-ish []
  "Return a locally monotonic millisecond-ish timestamp.
   os.time is second-grained, so IDs within the same second use a counter in
   the low millisecond field. This preserves local sort order without pulling
   in a platform-specific clock."
  (let [sec (os.time)]
    (if (= sec last-sec)
        (set per-sec-counter (% (+ per-sec-counter 1) 1000))
        (do (set last-sec sec)
            (set per-sec-counter 0)))
    (+ (* sec 1000) per-sec-counter)))

(fn M.uuidv7 []
  "Return a UUIDv7-shaped, time-sortable identifier string."
  (let [ts (timestamp-ms-ish)
        rand (M.random-hex 20)
        time-hex (string.format "%012x" ts)
        rand-a (string.sub rand 1 3)
        ;; RFC4122 variant: top two bits 10xx. Pick one of 8,9,a,b, then use
        ;; the remaining random hex for the rest of the UUID.
        variant-nibble (. ["8" "9" "a" "b"] (+ (% (string.byte rand 4) 4) 1))
        rest (string.sub rand 5 20)]
    (.. (string.sub time-hex 1 8) "-"
        (string.sub time-hex 9 12) "-"
        "7" rand-a "-"
        variant-nibble (string.sub rest 1 3) "-"
        (string.sub rest 4 15))))

M
