;; Shared helpers for built-in slash commands.

(local json (require :fen.util.json))

(local M {})

;; @doc fen.extensions.queue.util.approx-tokens
;; kind: function
;; signature: (approx-tokens s) -> number
;; summary: Estimate token count from text length for status displays when provider-reported usage is unavailable.
;; tags: commands tokens status
(fn M.approx-tokens [s]
  "Very rough tokenizer-independent estimate. Good enough for session status;
   provider-reported usage is authoritative for completed calls."
  (if (or (= s nil) (= s ""))
      0
      (math.ceil (/ (length (tostring s)) 4))))

;; @doc fen.extensions.queue.util.safe-json
;; kind: function
;; signature: (safe-json v) -> string
;; summary: JSON-encode a value for token estimation, falling back to tostring when encoding fails.
;; tags: commands json tokens
(fn M.safe-json [v]
  (let [(ok? s) (pcall json.encode v)]
    (if ok? s (tostring v))))

;; @doc fen.extensions.queue.util.content-tokens
;; kind: function
;; signature: (content-tokens content) -> number
;; summary: Estimate tokens for canonical message content, including text, thinking blocks, and tool-call names/arguments.
;; tags: commands tokens messages
(fn M.content-tokens [content]
  (if (= content nil)
      0
      (= (type content) :string)
      (M.approx-tokens content)
      (do
        (var n 0)
        (each [_ block (ipairs content)]
          (if (= block.type :text)
              (set n (+ n (M.approx-tokens block.text)))
              (= block.type :thinking)
              (set n (+ n (M.approx-tokens block.thinking)))
              (= block.type :tool-call)
              (set n (+ n
                        (M.approx-tokens block.name)
                        (M.approx-tokens (M.safe-json (or block.arguments {})))))))
        n)))

;; @doc fen.extensions.queue.util.estimated-context-tokens
;; kind: function
;; signature: (estimated-context-tokens agent) -> number
;; summary: Estimate the current agent context size from system prompt, messages, content blocks, and tool-result names.
;; tags: commands tokens agent
(fn M.estimated-context-tokens [agent]
  (var n (M.approx-tokens agent.system-prompt))
  (each [_ msg (ipairs (or agent.messages []))]
    (set n (+ n (M.approx-tokens msg.role) (M.content-tokens msg.content)))
    (when (= msg.role :tool-result)
      (set n (+ n (M.approx-tokens msg.tool-name)))))
  n)

;; @doc fen.extensions.queue.util.usage-totals
;; kind: function
;; signature: (usage-totals messages) -> Usage
;; summary: Sum provider usage counters across assistant messages for status and session diagnostics.
;; tags: commands tokens usage
(fn M.usage-totals [messages]
  (let [u {:input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0}]
    (each [_ msg (ipairs (or messages []))]
      (when (and (= msg.role :assistant) msg.usage)
        (set u.input (+ u.input (or msg.usage.input 0)))
        (set u.output (+ u.output (or msg.usage.output 0)))
        (set u.cache-read (+ u.cache-read (or msg.usage.cache-read 0)))
        (set u.cache-write (+ u.cache-write (or msg.usage.cache-write 0)))
        (set u.total-tokens (+ u.total-tokens
                               (or msg.usage.total-tokens
                                   (+ (or msg.usage.input 0)
                                      (or msg.usage.output 0)))))))
    u))

;; @doc fen.extensions.queue.util.fmt-tokens
;; kind: function
;; signature: (fmt-tokens n) -> string
;; summary: Format a token count compactly with raw, k, or M suffixes for slash-command status output.
;; tags: commands tokens format
(fn M.fmt-tokens [n]
  "Compact token formatter for /status."
  (let [n (or n 0)]
    (if (< n 1000) (tostring n)
        (< n 10000) (string.format "%.1fk" (/ n 1000))
        (< n 1000000) (string.format "%dk" (math.floor (/ n 1000)))
        (string.format "%.1fM" (/ n 1000000)))))

;; @doc fen.extensions.queue.util.format-token-summary
;; kind: function
;; signature: (format-token-summary usage approx) -> string
;; summary: Build the one-line input/output/cache/context token summary shown by /status.
;; tags: commands tokens status
(fn M.format-token-summary [usage approx]
  "One-line token breakdown for /status with no presenter/TUI dependency."
  (.. "↑" (M.fmt-tokens usage.input)
      " ↓" (M.fmt-tokens usage.output)
      " R" (M.fmt-tokens usage.cache-read)
      " W" (M.fmt-tokens usage.cache-write)
      "  ctx:~" (M.fmt-tokens approx)))

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
(fn M.nth-arg [args n]
  (let [pat (.. (string.rep "%S+%s+" (- n 1)) "(%S+)")]
    (string.match (or args "") pat)))

;; @doc fen.extensions.queue.util.first-arg
;; kind: function
;; signature: (first-arg args) -> string|nil
;; summary: Extract the first whitespace-delimited argument from a slash-command argument string.
;; tags: commands args parsing
(fn M.first-arg [args]
  (M.nth-arg args 1))

M
