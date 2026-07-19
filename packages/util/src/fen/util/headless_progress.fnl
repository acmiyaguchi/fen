;; Compact progress reporting shared by non-interactive presenters.
;;
;; Headless stdout is a result protocol, so progress is derived from the
;; existing event bus and written only to stderr. Every line is explicitly
;; flushed so redirected/background runs remain observable.

(local process (require :fen.util.process))

(local M {})

(local MAX_DETAIL 120)

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
  (let [clock (or (?. ?opts :clock) process.monotonic-ms)
        write-line (or (?. ?opts :write-line)
                       (fn [line]
                         (io.stderr:write line "\n")
                         (io.stderr:flush)))
        turns []]
    (fn [ev]
      (let [line
            (if (= ev.type :llm-start)
                (do
                  (table.insert turns (clock))
                  "[turn] started")
                (= ev.type :llm-end)
                (let [started (table.remove turns)
                      elapsed (elapsed-text (- (clock) (or started (clock))))
                      total (usage-total ev.usage)]
                  (if total
                      (.. "[turn] " (compact-number total) " tokens, " elapsed " elapsed")
                      (.. "[turn] complete, " elapsed " elapsed")))
                (= ev.type :tool-call)
                (let [name (clean-detail (or ev.name "unknown"))
                      detail (tool-detail ev.arguments)]
                  (.. "[tool] " name (if detail (.. " " detail) "")))
                (and (= ev.type :info) (= ev.source :goal))
                (let [iteration (or ev.iteration 0)
                      maximum (or ev.max-iterations "?")]
                  (if (= ev.decision :stop)
                      (.. "[goal] " (tostring ev.status) " " iteration "/" maximum)
                      (.. "[goal] iteration " iteration "/" maximum))))]
        (when line (write-line line))))))

(fn M.register [api]
  (api.on :* (M.make-handler))
  true)

M
