;; Text sanitation helpers for new tool results before they are emitted,
;; persisted, and later replayed to providers.
;;
;; Tool output can come from arbitrary subprocesses or extension code. Keep the
;; provider-visible text valid UTF-8, free of raw terminal/control bytes, and
;; bounded so one poison result cannot wedge a persisted session forever.

(local DEFAULT-MAX-TOOL-RESULT-BYTES 65536)
(local MAX-SCAN-BYTES 1048576)

;; @doc fen.util.text.trim
;; kind: function
;; signature: (trim s) -> string
;; summary: Strip leading and trailing ASCII whitespace; nil becomes "".
;; tags: util text
(fn trim [s]
  (or (string.match (or s "") "^%s*(.-)%s*$") ""))

;; @doc fen.util.text.first-line
;; kind: function
;; signature: (first-line s) -> string
;; summary: Return the substring up to the first newline; nil becomes "".
;; tags: util text
(fn first-line [s]
  (let [text (tostring (or s ""))
        i (string.find text "\n" 1 true)]
    (if i (string.sub text 1 (- i 1)) text)))

(fn parse-positive-int [s]
  (let [n (tonumber s)]
    (when (and n (> n 0)) (math.floor n))))

(fn default-tool-result-max-bytes []
  (or (parse-positive-int (os.getenv :FEN_TOOL_RESULT_MAX_BYTES))
      DEFAULT-MAX-TOOL-RESULT-BYTES))

(fn max-bytes [opts]
  (or (and opts (parse-positive-int opts.max-bytes))
      (default-tool-result-max-bytes)))

(fn hex-byte [b]
  (string.format "\\x%02X" b))

(fn control-byte? [b]
  (or (< b 32) (= b 127)))

(fn allowed-ascii-control? [b]
  (or (= b 9) (= b 10) (= b 13)))

(fn continuation? [b]
  (and b (>= b 128) (<= b 191)))

(fn utf8-seq-len [s i n b]
  "Return the valid UTF-8 sequence length at byte i, or nil. Rejects overlong
   forms, surrogates, and code points above U+10FFFF."
  (if (and (>= b 194) (<= b 223))
      (let [b2 (string.byte s (+ i 1))]
        (when (and (<= (+ i 1) n) (continuation? b2))
          2))
      (and (>= b 224) (<= b 239))
      (let [b2 (string.byte s (+ i 1))
            b3 (string.byte s (+ i 2))]
        (when (and (<= (+ i 2) n)
                   (continuation? b3)
                   (if (= b 224)
                       (and b2 (>= b2 160) (<= b2 191))
                       (= b 237)
                       (and b2 (>= b2 128) (<= b2 159))
                       (continuation? b2)))
          3))
      (and (>= b 240) (<= b 244))
      (let [b2 (string.byte s (+ i 1))
            b3 (string.byte s (+ i 2))
            b4 (string.byte s (+ i 3))]
        (when (and (<= (+ i 3) n)
                   (continuation? b3)
                   (continuation? b4)
                   (if (= b 240)
                       (and b2 (>= b2 144) (<= b2 191))
                       (= b 244)
                       (and b2 (>= b2 128) (<= b2 143))
                       (continuation? b2)))
          4))
      nil))

(fn utf8-control-codepoint [s i n b]
  "Return a C1 control codepoint for valid two-byte U+0080..U+009F, else nil."
  (when (and (= b 194) (<= (+ i 1) n))
    (let [b2 (string.byte s (+ i 1))]
      (when (and b2 (>= b2 128) (<= b2 159))
        b2))))

(fn clean-printable-ascii? [s]
  (let [(pos _) (string.find s "[^\t\n\r -~]")]
    (= pos nil)))

;; @doc fen.util.text.sanitize
;; kind: function
;; signature: (sanitize s) -> {:text :changed? :unsafe-count :invalid-count :input-bytes}
;; summary: Escape unsafe control bytes and invalid UTF-8 while preserving valid text and \n/\r/\t.
;; tags: util text tools sessions providers
(fn sanitize [s]
  (let [input (tostring (or s ""))
        n (length input)]
    (if (clean-printable-ascii? input)
        {:text input
         :input-bytes n
         :unsafe-count 0
         :invalid-count 0
         :changed? false}
        (let [out []
              stats {:input-bytes n
                     :unsafe-count 0
                     :invalid-count 0
                     :changed? false}]
          (var i 1)
          (while (<= i n)
            (let [b (string.byte input i)
                  c1 (utf8-control-codepoint input i n b)]
              (if (and (control-byte? b) (not (allowed-ascii-control? b)))
                  (do
                    (table.insert out (hex-byte b))
                    (set stats.unsafe-count (+ stats.unsafe-count 1))
                    (set stats.changed? true)
                    (set i (+ i 1)))
                  (< b 128)
                  (do
                    (table.insert out (string.char b))
                    (set i (+ i 1)))
                  c1
                  (do
                    (table.insert out (hex-byte c1))
                    (set stats.unsafe-count (+ stats.unsafe-count 1))
                    (set stats.changed? true)
                    (set i (+ i 2)))
                  (let [seq-len (utf8-seq-len input i n b)]
                    (if seq-len
                        (do
                          (table.insert out (string.sub input i (+ i seq-len -1)))
                          (set i (+ i seq-len)))
                        (do
                          (table.insert out (hex-byte b))
                          (set stats.invalid-count (+ stats.invalid-count 1))
                          (set stats.changed? true)
                          (set i (+ i 1))))))))
          (set stats.text (table.concat out))
          stats))))

(fn utf8-len-at [s i n]
  (let [b (string.byte s i)]
    (if (< b 128)
        1
        (or (utf8-seq-len s i n b) 1))))

(fn utf8-prefix [s limit]
  "Return a prefix of at most limit bytes without splitting a valid UTF-8 sequence."
  (let [n (length s)]
    (if (>= limit n)
        s
        (let []
          (var out-end 0)
          (var i 1)
          (var used 0)
          (while (<= i n)
            (let [seq-len (utf8-len-at s i n)]
              (if (<= (+ used seq-len) limit)
                  (do
                    (set used (+ used seq-len))
                    (set out-end (+ i seq-len -1))
                    (set i (+ i seq-len)))
                  (set i (+ n 1)))))
          (string.sub s 1 out-end)))))

;; @doc fen.util.text.scrub-tool-text
;; kind: function
;; signature: (scrub-tool-text s ?opts) -> {:text :changed? :note :unsafe-count :invalid-count :truncated? :input-bytes :sanitized-bytes :kept-bytes :max-bytes}
;; summary: Sanitize and cap provider-visible tool output text, appending an explicit marker when changed.
;; tags: util text tools sessions providers
(fn scrub-tool-text [s ?opts]
  (let [input (tostring (or s ""))
        input-bytes (length input)
        limit (max-bytes ?opts)
        ;; Do not build a table entry for every byte of an unbounded tool
        ;; result only to throw almost all of it away. Scan just past the kept
        ;; prefix, with an upper clamp so an environment override cannot
        ;; re-enable unbounded scans; sanitize handles a split trailing UTF-8
        ;; sequence safely.
        scan-bytes (math.min (+ limit 4) MAX-SCAN-BYTES)
        raw-truncated? (> input-bytes scan-bytes)
        scan-input (if raw-truncated?
                       (string.sub input 1 scan-bytes)
                       input)
        cleaned (sanitize scan-input)
        sanitized cleaned.text
        sanitized-bytes (length sanitized)
        over? (or raw-truncated? (> sanitized-bytes limit))
        kept (if over? (utf8-prefix sanitized limit) sanitized)
        kept-bytes (length kept)
        notes []]
    (when (> (+ cleaned.unsafe-count cleaned.invalid-count) 0)
      (table.insert notes
                    (.. "[fen: tool output sanitized: "
                        (+ cleaned.unsafe-count cleaned.invalid-count)
                        " unsafe bytes escaped]")))
    (when over?
      (table.insert notes
                    (if raw-truncated?
                        (.. "[fen: tool output truncated: kept " kept-bytes
                            " sanitized bytes from " input-bytes " input bytes]")
                        (.. "[fen: tool output truncated: kept " kept-bytes
                            " of " sanitized-bytes " sanitized bytes]"))))
    (let [note (when (> (length notes) 0) (table.concat notes "\n"))]
      {:text (if note
                 (if (= kept "") note (.. kept "\n\n" note))
                 kept)
       :note note
       :changed? (or cleaned.changed? over?)
       :unsafe-count cleaned.unsafe-count
       :invalid-count cleaned.invalid-count
       :truncated? over?
       :raw-truncated? raw-truncated?
       :input-bytes input-bytes
       :sanitized-bytes sanitized-bytes
       :kept-bytes kept-bytes
       :max-bytes limit})))

{: DEFAULT-MAX-TOOL-RESULT-BYTES
 : MAX-SCAN-BYTES
 : default-tool-result-max-bytes
 : trim
 : first-line
 : sanitize
 : scrub-tool-text}
