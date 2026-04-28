;; Shared helpers for built-in slash commands.

(local json (require :util.json))

(local M {})

(fn M.approx-tokens [s]
  "Very rough tokenizer-independent estimate. Good enough for session status;
   provider-reported usage is authoritative for completed calls."
  (if (or (= s nil) (= s ""))
      0
      (math.ceil (/ (length (tostring s)) 4))))

(fn M.safe-json [v]
  (let [(ok? s) (pcall json.encode v)]
    (if ok? s (tostring v))))

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

(fn M.estimated-context-tokens [agent]
  (var n (M.approx-tokens agent.system-prompt))
  (each [_ msg (ipairs (or agent.messages []))]
    (set n (+ n (M.approx-tokens msg.role) (M.content-tokens msg.content)))
    (when (= msg.role :tool-result)
      (set n (+ n (M.approx-tokens msg.tool-name)))))
  n)

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

(fn M.fmt-tokens [n]
  "Compact token formatter for /status."
  (let [n (or n 0)]
    (if (< n 1000) (tostring n)
        (< n 10000) (string.format "%.1fk" (/ n 1000))
        (< n 1000000) (string.format "%dk" (math.floor (/ n 1000)))
        (string.format "%.1fM" (/ n 1000000)))))

(fn M.format-token-summary [usage approx]
  "One-line token breakdown for /status with no presenter/TUI dependency."
  (.. "↑" (M.fmt-tokens usage.input)
      " ↓" (M.fmt-tokens usage.output)
      " R" (M.fmt-tokens usage.cache-read)
      " W" (M.fmt-tokens usage.cache-write)
      "  ctx:~" (M.fmt-tokens approx)))

(fn M.runtime-version []
  "Return the build-stamped version string, or unknown when running from
   source/tests without dist/version.lua."
  (let [(ok? v) (pcall require :version)]
    (if (and ok? v) (tostring v) "unknown")))

(fn M.nth-arg [args n]
  (let [pat (.. (string.rep "%S+%s+" (- n 1)) "(%S+)")]
    (string.match (or args "") pat)))

(fn M.first-arg [args]
  (M.nth-arg args 1))

M
