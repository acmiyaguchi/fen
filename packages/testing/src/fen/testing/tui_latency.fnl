;; Scheduled external boundaries around the *production* presenter loop.
;; Require before any TUI module: those modules capture the termbox table.
(local h (require :fen.testing.tui))
(local socket (require :socket))
(local tb (h.install-termbox-stub! {:capture? true :cols 100 :rows 32}))
(local tui (require :fen.extensions.tui))
(local state (require :fen.extensions.tui.state))
(local paint (require :fen.extensions.tui.paint))
(local clock (require :fen.util.clock))
(local api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local M {})

(fn M.stats [measurements]
  (let [sorted []]
    (each [_ v (ipairs measurements)] (table.insert sorted v))
    (table.sort sorted)
    (let [n (length sorted)]
      {:n n
       :median (if (> n 0)
                   (/ (+ (. sorted (math.floor (/ (+ n 1) 2)))
                         (. sorted (math.ceil (/ (+ n 1) 2))))
                      2)
                   0)
       :p95 (or (. sorted (math.ceil (* n 0.95))) 0)
       :max (or (. sorted n) 0)})))

(fn M.seed! [n]
  ;; Historical rows are seeded outside the timed loop; first paint is cold.
  (for [i 1 n]
    (table.insert state.transcript
                  (if (= (% i 5) 0)
                      {:type :user
                       :text (.. "Explain the change in module " i)}
                      (= (% i 5) 1)
                      {:type :tool-result
                       :name :read
                       :id (tostring i)
                       :result {:content [{:type :text
                                           :text (string.rep "source line\n" 30)}]}}
                      {:type :assistant-text
                       :text (.. "## Investigation " i "\n"
                                 "The **implementation** uses `module.fn` for reload-safe dispatch.\n"
                                 "- inspect state\n- run focused tests\n\n"
                                 "```lua\nreturn module.fn(state)\n```\n"
                                 (string.rep "A realistic wrapped explanation of the observed behavior. "
                                             8))}))))

(fn M.run [opts]
  "Replay scheduled keys and bus events. Fake mode advances only waits/stalls;
   wall mode really waits and measures arrival deadlines to tb.present return.
   No rendering, input, ingestion, batching or poll policy is reimplemented."
  (h.reset-state! {:cols (or opts.cols 100)
                   :rows (or opts.rows 32)
                   :markdown? true})
  (api.reset!)
  (tui.register (api.make-runtime-api :latency))
  (set state.tb-initialized? true)
  (set state.animations? (not= opts.animations? false))
  (when opts.thinking? (events.emit {:type :llm-start}))
  (M.seed! (or opts.history 0))
  (set tb.present-count 0)
  (set tb.width-value state.tb-cols)
  (set tb.height-value state.tb-rows)
  (local keys (or opts.keys []))
  (local deltas (or opts.deltas []))
  (local samples [])
  (local polls [])
  (local frames [])
  (local frame-cpu [])
  (var virtual 0)
  (var ki 1)
  (var di 1)
  (var draft "")
  (var ended? false)
  (var ticks 0)
  (local wall-start (socket.gettime))
  (local cpu-start (os.clock))

  (fn now []
    (if opts.wall? (* 1000 (- (socket.gettime) wall-start)) virtual))

  (fn advance! [ms]
    (when (> ms 0)
      (if opts.wall? (socket.sleep (/ ms 1000)) (set virtual (+ virtual ms)))))

  (fn watch! [item kind text]
    (table.insert samples {:kind kind :at item.at :text text :delivered (now)}))

  (local old-present tb.present)
  (local old-peek tb.peek_event)
  (local old-clock clock.monotonic-ms)
  (local old-redraw paint.redraw-if-needed!)
  (set paint.redraw-if-needed!
       (fn []
         (let [before tb.present-count
               start (os.clock)]
           (old-redraw)
           (when (> tb.present-count before)
             (table.insert frame-cpu (* 1000 (- (os.clock) start)))))))
  (set clock.monotonic-ms now)
  (set tb.present (fn []
                    (advance! (or opts.present-delay-ms 0))
                    (old-present)
                    (let [text (table.concat (h.presented-screen-lines tb) "\n")
                          at (now)]
                      (when opts.frames?
                        (table.insert frames {:at at :text text}))
                      (each [_ sample (ipairs samples)]
                        (when (and (= sample.visible nil)
                                   (string.find text sample.text 1 true))
                          (set sample.visible at)
                          (set sample.latency (- at sample.at)))))
                    0))
  (local finish-at (or opts.finish-at 2000))
  (set tb.peek_event
       (fn [timeout]
         (table.insert polls timeout)
         (assert (< (length polls) 10000) "latency replay exceeded loop budget")
         (let [key (. keys ki)
               target (+ (now) timeout)]
           ;; Only terminal input wakes termbox. Provider readiness waits for
           ;; the production on-tick callback after the actual poll timeout.
           (if (and key (<= key.at target))
               (do
                 (advance! (- key.at (now)))
                 (set ki (+ ki 1))
                 (set draft (.. draft key.text))
                 (watch! key :input draft)
                 {:type tb.EVENT_KEY
                  :key 0
                  :ch (string.byte key.text)
                  :utf8 key.text
                  :mod 0})
               (>= target finish-at)
               (do
                 (advance! (- finish-at (now)))
                 ;; Clear the draft and quit via the production input path.
                 (if (not= state.input-buf "")
                     {:type tb.EVENT_KEY :key tb.KEY_CTRL_U :ch 0 :mod 0}
                     {:type tb.EVENT_KEY :key tb.KEY_CTRL_D :ch 0 :mod 0}))
               (do
                 (advance! timeout)
                 (values nil "no event" tb.ERR_NO_EVENT))))))

  (fn tick! []
    (set ticks (+ ticks 1))
    (when (= ticks (or opts.stall-tick -1))
      (advance! (or opts.tick-delay-ms 0)))
    (while (and (. deltas di) (<= (. deltas di :at) (now)))
      (let [delta (. deltas di)]
        (watch! delta :delta delta.marker)
        (events.emit {:type :assistant-text-delta
                      :content-index 1
                      :delta delta.text})
        (set di (+ di 1))))
    (when (and opts.end-at (not ended?) (>= (now) opts.end-at))
      (set ended? true)
      (events.emit {:type :assistant-stream-end :final? true})))

  (let [(ok? err) (xpcall #(tui.run (fn [_]) tick! (fn [])
                                    #(not= opts.busy? false))
                          debug.traceback)
        wall-ms (* 1000 (- (socket.gettime) wall-start))
        cpu-ms (* 1000 (- (os.clock) cpu-start))]
    (set tb.present old-present)
    (set tb.peek_event old-peek)
    (set clock.monotonic-ms old-clock)
    (set paint.redraw-if-needed! old-redraw)
    (set state.tb-initialized? false)
    (when (not ok?) (error err))
    (let [input []
          delta []
          missing []]
      (each [_ s (ipairs samples)]
        (if s.latency
            (table.insert (if (= s.kind :input) input delta) s.latency)
            (table.insert missing s)))
      {:input (M.stats input)
       :delta (M.stats delta)
       : samples
       : missing
       : polls
       : frames
       :cpu-ms cpu-ms
       :wall-ms wall-ms
       :logical-ms virtual
       :frame-cpu (M.stats frame-cpu)
       :presents tb.present-count
       :ticks ticks
       :draft draft})))

M
