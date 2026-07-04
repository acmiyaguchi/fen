;; Small helpers for streamed string fields.
;;
;; Provider reducers receive text/tool-argument deltas in many small pieces.
;; Repeated `..` accumulation copies the full prefix on every delta; these
;; helpers keep chunk arrays during streaming and materialize only at block
;; boundaries or when a final value is supplied.

(local M {})

(fn string? [x]
  (= (type x) :string))

;; @doc fen.util.stream_chunks.append!
;; kind: function
;; signature: (append! rec value-key chunks-key delta) -> nil
;; summary: Append a non-empty string delta to an internal chunk list without concatenating the accumulated value.
;; tags: util streaming chunks
(fn M.append! [rec value-key chunks-key delta]
  (when (and rec (string? delta) (not= delta ""))
    (var chunks (. rec chunks-key))
    (when (= chunks nil)
      (set chunks [])
      (let [initial (. rec value-key)]
        (when (and (string? initial) (not= initial ""))
          (table.insert chunks initial)))
      (tset rec chunks-key chunks))
    (table.insert chunks delta))
  nil)

;; @doc fen.util.stream_chunks.value
;; kind: function
;; signature: (value rec value-key chunks-key) -> string
;; summary: Return the current logical string value, concatenating chunks only for this read.
;; tags: util streaming chunks
(fn M.value [rec value-key chunks-key]
  (if (not rec)
      ""
      (let [chunks (. rec chunks-key)]
        (if chunks
            (table.concat chunks "")
            (let [value (. rec value-key)]
              (if (string? value) value ""))))))

;; @doc fen.util.stream_chunks.materialize!
;; kind: function
;; signature: (materialize! rec value-key chunks-key) -> string
;; summary: Concatenate any pending chunks into value-key, clear the chunk list, and return the materialized string.
;; tags: util streaming chunks
(fn M.materialize! [rec value-key chunks-key]
  (if (not rec)
      ""
      (let [chunks (. rec chunks-key)]
        (when chunks
          (tset rec value-key (table.concat chunks ""))
          (tset rec chunks-key nil))
        (M.value rec value-key chunks-key))))

;; @doc fen.util.stream_chunks.set!
;; kind: function
;; signature: (set! rec value-key chunks-key value) -> string
;; summary: Replace a streamed value with the final string and discard pending chunks.
;; tags: util streaming chunks
(fn M.set! [rec value-key chunks-key value]
  (let [s (if (string? value) value "")]
    (when rec
      (tset rec value-key s)
      (tset rec chunks-key nil))
    s))

M
