;; Busy panel: spinner + label + elapsed timer above the input row while
;; the agent is running. Collapses to height 0 when idle so the layout
;; gives the row back to the transcript.
;;
;; Registered as a first-party :panel by the TUI extension at init time.
;; Kept in the TUI extension because the spec reads tui state.status-info
;; — extensions outside the TUI shouldn't reach into that state.

(local state (require :fen.extensions.tui.state))

(local M {})

(local SPINNER-FRAMES ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])

(fn M.spin-char []
  (if (not state.animations?)
      "•"
      (let [s state.status-info
            frame (or s.spin-frame 0)
            idx (+ (% frame (length SPINNER-FRAMES)) 1)]
        (or (. SPINNER-FRAMES idx) "⠋"))))

(fn M.turn-elapsed []
  "Seconds since the current turn started, or empty string when idle."
  (let [s state.status-info
        start (or s.turn-start 0)]
    (if (= start 0) ""
        (.. (tostring (- (os.time) start)) "s"))))

(fn fmt-delay [ms]
  (let [n (or ms 0)]
    (if (>= n 1000)
        (.. (string.format "%.1f" (/ n 1000)) "s")
        (.. (tostring n) "ms"))))

(fn busy-label []
  (let [s state.status-info]
    (if s.retrying?
        (.. "retrying " (tostring (or s.retry-attempt 0))
            "/" (tostring (or s.retry-max-attempts 0))
            " in " (fmt-delay s.retry-delay-ms)
            (if s.retry-reason (.. " after " (tostring s.retry-reason)) ""))
        (or s.running-label (if s.thinking? "thinking" "")))))

(fn busy? []
  (not= (busy-label) ""))

(fn M.height [_ctx]
  (if (busy?) 1 0))

(fn M.render [_ctx]
  (if (busy?)
      (let [elapsed (M.turn-elapsed)
            text (.. "  " (M.spin-char) " " (busy-label)
                     (if (not= elapsed "") (.. "  " elapsed) ""))]
        [{:text text :style :dim}])
      []))

(fn M.spec []
  {:name :busy
   :placement :above-input
   :order 10
   :height M.height
   :render M.render})

M
