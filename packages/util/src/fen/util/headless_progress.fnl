;; Progress to stderr only (stdout is a result protocol); every line flushed for redirected runs.

(local clock-mod (require :fen.util.clock))

(local M {})

(local MAX_DETAIL 120)

;; Rate-limit heartbeats: streaming deltas can arrive dozens of times per second.
(local HEARTBEAT_MS 1000)

(fn clean-detail [value]
  (when value
    (let [text (string.gsub (tostring value) "%s+" " ")]
      (if (> (length text) MAX_DETAIL)
          (.. (string.sub text 1 (- MAX_DETAIL 1)) "…")
          text))))

(fn compact-number [n]
  (if (>= n 1000)
      (string.gsub (string.format "%.1fk" (/ n 1000)) "%.0k" "k")
      (tostring (math.floor n))))

(fn elapsed-text [ms]
  (let [seconds (/ (math.max 0 ms) 1000)]
    (if (>= seconds 10)
        (.. (math.floor seconds) "s")
        (string.gsub (string.format "%.1fs" seconds) "%.0s" "s"))))

(fn usage-total [usage]
  (when usage
    (or (. usage :total-tokens)
        (. usage :total_tokens)
        (. usage :total)
        (let [input (or (. usage :input) (. usage :input-tokens)
                        (. usage :input_tokens))
              output (or (. usage :output) (. usage :output-tokens)
                         (. usage :output_tokens))]
          (when (or input output)
            (+ (or input 0) (or output 0)))))))

(fn tool-detail [arguments]
  (when (= (type arguments) :table)
    (clean-detail
      (or arguments.path arguments.file_path arguments.file
          arguments.query arguments.pattern arguments.cmd arguments.command))))

(fn M.make-handler [?opts]
  ;; Non-streaming providers emit no mid-turn heartbeat (no runtime timer); the summary still lands at :llm-end.
  (let [clock (or (?. ?opts :clock) clock-mod.monotonic-ms)
        heartbeat-ms (or (?. ?opts :heartbeat-ms) HEARTBEAT_MS)
        write-line (or (?. ?opts :write-line)
                       (fn [line]
                         (io.stderr:write line "\n")
                         (io.stderr:flush)))
        turns []
        heartbeat {:last nil}]
    (fn [ev]
      (let [line
            (if (= ev.type :llm-start)
                (let [now (clock)]
                  (table.insert turns now)
                  (set heartbeat.last now)
                  "[turn] started")
                (= ev.type :llm-end)
                (let [started (table.remove turns)
                      elapsed (elapsed-text (- (clock) (or started (clock))))
                      total (usage-total ev.usage)]
                  (set heartbeat.last nil)
                  (if total
                      (.. "[turn] " (compact-number total) " tokens, " elapsed " elapsed")
                      (.. "[turn] complete, " elapsed " elapsed")))
                (or (= ev.type :assistant-text-delta)
                    (= ev.type :assistant-thinking-delta))
                ;; Content-free: never echo text or reasoning, only elapsed time.
                (let [started (. turns (length turns))]
                  (when (and started heartbeat.last)
                    (let [now (clock)]
                      (when (>= (- now heartbeat.last) heartbeat-ms)
                        (set heartbeat.last now)
                        (.. "[turn] " (elapsed-text (- now started)) " elapsed")))))
                (= ev.type :tool-call)
                (let [name (clean-detail (or ev.name "unknown"))
                      detail (tool-detail ev.arguments)]
                  (.. "[tool] " name (if detail (.. " " detail) "")))
                (and (= ev.type :info) (= ev.source :goal))
                (let [raw (or ev.iteration 0)
                      ;; Goal :start means iteration one is in flight; render 1 even if the event carries 0.
                      iteration (if (and (= ev.decision :start) (< raw 1)) 1 raw)
                      maximum (or ev.max-iterations "?")]
                  (if (= ev.decision :stop)
                      (.. "[goal] " (tostring ev.status) " " iteration "/" maximum)
                      (.. "[goal] iteration " iteration "/" maximum))))]
        (when line (write-line line))))))

(fn M.register [api]
  (api.on :* (M.make-handler))
  true)

M
