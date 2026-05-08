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

;; @doc fen.extensions.tui.panels.busy.spin-char
;; kind: function
;; signature: (spin-char) -> string
;; summary: Return the current busy indicator glyph, respecting the animation toggle and spinner frame counter.
;; tags: tui panel busy spinner
(fn M.spin-char []
  (if (not state.animations?)
      "•"
      (let [s state.status-info
            frame (or s.spin-frame 0)
            idx (+ (% frame (length SPINNER-FRAMES)) 1)]
        (or (. SPINNER-FRAMES idx) "⠋"))))

;; @doc fen.extensions.tui.panels.busy.turn-elapsed
;; kind: function
;; signature: (turn-elapsed) -> string
;; summary: Return elapsed turn time text for the busy panel, or an empty string when no turn is active.
;; tags: tui panel busy timing
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

;; @doc fen.extensions.tui.panels.busy.height
;; kind: function
;; signature: (height ctx) -> number
;; summary: Reserve one above-input row only while thinking, retrying, or running a tool.
;; tags: tui panel busy layout
(fn M.height [_ctx]
  (if (busy?) 1 0))

;; @doc fen.extensions.tui.panels.busy.render
;; kind: function
;; signature: (render ctx) -> [PresenterRow]
;; summary: Render spinner, busy label, retry delay, and elapsed time rows for the active turn.
;; tags: tui panel busy render
(fn M.render [_ctx]
  (if (busy?)
      (let [elapsed (M.turn-elapsed)
            text (.. "  " (M.spin-char) " " (busy-label)
                     (if (not= elapsed "") (.. "  " elapsed) ""))]
        [{:text text :style :dim}])
      []))

;; @doc fen.extensions.tui.panels.busy.spec
;; kind: function
;; signature: (spec) -> PanelSpec
;; summary: Return the built-in busy panel contribution that appears above the input while work is active.
;; tags: tui panel busy register
(fn M.spec []
  {:name :busy
   :placement :above-input
   :order 10
   :height M.height
   :render M.render})

M
