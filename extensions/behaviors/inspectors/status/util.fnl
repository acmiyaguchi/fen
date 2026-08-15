;; Status-specific helpers. Token/arg primitives live in fen.util.tokens and
;; fen.util.args; only the status-only formatting stays here.

(local M {})

(fn M.last-turn-latency [messages]
  "Compact 'N.Ns (M.M tok/s)' for the latest assistant message that carries a
   measured usage.latency-ms. nil when none is measured yet (older transcripts,
   or before the first turn completes)."
  (var found nil)
  (each [_ msg (ipairs (or messages []))]
    (when (and (= msg.role :assistant)
               msg.usage
               (= (type msg.usage.latency-ms) :number))
      (set found msg.usage)))
  (when found
    (let [secs (/ found.latency-ms 1000)
          out (or found.output 0)
          tps (if (> secs 0) (/ out secs) 0)]
      (string.format "%.1fs (%.1f tok/s)" secs tps))))

(fn M.runtime-version []
  "Return the build-stamped version string, or source/git fallback when
   running from a checkout."
  (let [(ok? v) (pcall require :fen.version)]
    (if (and ok? (= (type v) :table) (= (type v.format) :function))
        (v.format)
        (and ok? (= (type v) :table))
        (.. (tostring (or v.version "unknown"))
            " (" (tostring (or v.source "unknown"))
            (if v.targetSystem (.. ", " (tostring v.targetSystem)) "")
            ")")
        (and ok? v)
        (tostring v)
        "unknown")))

M
