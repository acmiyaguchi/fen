;; Shared helpers for built-in slash commands.

(local tokens (require :fen.util.tokens))

(local M {})

;; @doc fen.extensions.status.util.approx-tokens
;; kind: function
;; signature: (approx-tokens s) -> number
;; summary: Estimate token count from text length for status displays when provider-reported usage is unavailable.
;; tags: commands tokens status
(fn M.approx-tokens [s] (tokens.approx-tokens s))

;; @doc fen.extensions.status.util.safe-json
;; kind: function
;; signature: (safe-json v) -> string
;; summary: JSON-encode a value for token estimation, falling back to tostring when encoding fails.
;; tags: commands json tokens
(fn M.safe-json [v] (tokens.safe-json v))

;; @doc fen.extensions.status.util.content-tokens
;; kind: function
;; signature: (content-tokens content) -> number
;; summary: Estimate tokens for canonical message content, including text, thinking blocks, and tool-call names/arguments.
;; tags: commands tokens messages
(fn M.content-tokens [content] (tokens.content-tokens content))

;; @doc fen.extensions.status.util.estimated-context-tokens
;; kind: function
;; signature: (estimated-context-tokens agent) -> number
;; summary: Estimate the current agent context size from system prompt, messages, content blocks, and tool-result names.
;; tags: commands tokens agent
(fn M.estimated-context-tokens [agent]
  (tokens.estimated-context-tokens agent))

;; @doc fen.extensions.status.util.usage-totals
;; kind: function
;; signature: (usage-totals messages) -> Usage
;; summary: Sum provider usage counters across assistant messages for status and session diagnostics.
;; tags: commands tokens usage
(fn M.usage-totals [messages] (tokens.usage-totals messages))

;; @doc fen.extensions.status.util.last-turn-latency
;; kind: function
;; signature: (last-turn-latency messages) -> string|nil
;; summary: Format the most recent measured assistant turn's latency and output tok/s for /status, or nil when no turn carries a measured latency.
;; tags: commands latency status
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

;; @doc fen.extensions.status.util.fmt-tokens
;; kind: function
;; signature: (fmt-tokens n) -> string
;; summary: Format a token count compactly with raw, k, or M suffixes for slash-command status output.
;; tags: commands tokens format
(fn M.fmt-tokens [n] (tokens.fmt-tokens n))

;; @doc fen.extensions.status.util.format-token-summary
;; kind: function
;; signature: (format-token-summary usage approx) -> string
;; summary: Build the one-line input/output/cache/context token summary shown by /status.
;; tags: commands tokens status
(fn M.format-token-summary [usage approx]
  (tokens.format-token-summary usage approx))

;; @doc fen.extensions.status.util.runtime-version
;; kind: function
;; signature: (runtime-version) -> string
;; summary: Return the build-stamped fen version, or unknown when running from source/tests without dist metadata.
;; tags: commands status version
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

;; @doc fen.extensions.status.util.nth-arg
;; kind: function
;; signature: (nth-arg args n) -> string|nil
;; summary: Extract the nth whitespace-delimited argument from a slash-command argument string.
;; tags: commands args parsing
(fn M.nth-arg [args n]
  (let [pat (.. (string.rep "%S+%s+" (- n 1)) "(%S+)")]
    (string.match (or args "") pat)))

;; @doc fen.extensions.status.util.first-arg
;; kind: function
;; signature: (first-arg args) -> string|nil
;; summary: Extract the first whitespace-delimited argument from a slash-command argument string.
;; tags: commands args parsing
(fn M.first-arg [args]
  (M.nth-arg args 1))

M
