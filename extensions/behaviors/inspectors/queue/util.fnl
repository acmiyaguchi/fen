;; Shared helpers for queue slash commands.

(local tokens (require :fen.util.tokens))
(local args-util (require :fen.util.args))

(local M {})

;; @doc fen.extensions.queue.util.approx-tokens
;; kind: function
;; signature: (approx-tokens s) -> number
;; summary: Estimate token count from text length for status displays when provider-reported usage is unavailable.
;; tags: commands tokens status
(fn M.approx-tokens [s] (tokens.approx-tokens s))

;; @doc fen.extensions.queue.util.safe-json
;; kind: function
;; signature: (safe-json v) -> string
;; summary: JSON-encode a value for token estimation, falling back to tostring when encoding fails.
;; tags: commands json tokens
(fn M.safe-json [v] (tokens.safe-json v))

;; @doc fen.extensions.queue.util.content-tokens
;; kind: function
;; signature: (content-tokens content) -> number
;; summary: Estimate tokens for canonical message content, including text, thinking blocks, and tool-call names/arguments.
;; tags: commands tokens messages
(fn M.content-tokens [content] (tokens.content-tokens content))

;; @doc fen.extensions.queue.util.estimated-context-tokens
;; kind: function
;; signature: (estimated-context-tokens agent) -> number
;; summary: Estimate the current agent context size from system prompt, messages, content blocks, and tool-result names.
;; tags: commands tokens agent
(fn M.estimated-context-tokens [agent]
  (tokens.estimated-context-tokens agent))

;; @doc fen.extensions.queue.util.usage-totals
;; kind: function
;; signature: (usage-totals messages) -> Usage
;; summary: Sum provider usage counters across assistant messages for status and session diagnostics.
;; tags: commands tokens usage
(fn M.usage-totals [messages] (tokens.usage-totals messages))

;; @doc fen.extensions.queue.util.fmt-tokens
;; kind: function
;; signature: (fmt-tokens n) -> string
;; summary: Format a token count compactly with raw, k, or M suffixes for slash-command status output.
;; tags: commands tokens format
(fn M.fmt-tokens [n] (tokens.fmt-tokens n))

;; @doc fen.extensions.queue.util.format-token-summary
;; kind: function
;; signature: (format-token-summary usage approx) -> string
;; summary: Build the one-line input/output/cache/context token summary shown by /status.
;; tags: commands tokens status
(fn M.format-token-summary [usage approx]
  (tokens.format-token-summary usage approx))

;; @doc fen.extensions.queue.util.runtime-version
;; kind: function
;; signature: (runtime-version) -> string
;; summary: Return the build-stamped fen version, or unknown when running from source/tests without dist metadata.
;; tags: commands status version
(fn M.runtime-version []
  "Return the build-stamped version string, or unknown when running from
   source/tests without dist/version.lua."
  (let [(ok? v) (pcall require :fen.version)]
    (if (and ok? v) (tostring v) "unknown")))

;; @doc fen.extensions.queue.util.nth-arg
;; kind: function
;; signature: (nth-arg args n) -> string|nil
;; summary: Extract the nth whitespace-delimited argument from a slash-command argument string.
;; tags: commands args parsing
(fn M.nth-arg [args n] (args-util.nth-arg args n))

;; @doc fen.extensions.queue.util.first-arg
;; kind: function
;; signature: (first-arg args) -> string|nil
;; summary: Extract the first whitespace-delimited argument from a slash-command argument string.
;; tags: commands args parsing
(fn M.first-arg [args] (args-util.first-arg args))

M
