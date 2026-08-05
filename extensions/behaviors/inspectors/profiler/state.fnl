;; Persistent statistical profiler capture state. Not reloadable.
;;
;; The debug hook and bounded capture data live here so a recording survives
;; /reload. Commands, formatting, and export remain reloadable siblings.

(local coroutines (require :fen.util.coroutines))
(local clock (require :fen.util.clock))

(local M
  {:enabled? false
   :period 25000
   :mode :functions
   :max-frames 20000
   :max-stacks 50000
   :max-depth 128
   :max-threads 1024
   :frames []
   :frame-ids {}
   :stacks []
   :stack-ids {}
   :stack-threads {}
   :counts {}
   :sample-count 0
   :dropped-samples 0
   :wall-gaps []
   :dropped-wall-gaps 0
   :marks []
   :spans []
   :dropped-spans 0
   :counters {}
   :counter-count 0
   :dropped-counters 0
   :max-wall-gaps 2000
   :max-marks 200
   :max-spans 2000
   :max-counters 64
   :wall-gap-ms 25
   :started-wall nil
   :started-cpu nil
   :stopped-wall nil
   :stopped-cpu nil
   :threads {}
   :thread-count 0
   :thread-refs (setmetatable {} {:__mode :v})
   :generation 0
   :env-started? false
   :hook nil})

(fn clear-capture! []
  (set M.frames [])
  (set M.frame-ids {})
  (set M.stacks [])
  (set M.stack-ids {})
  (set M.stack-threads {})
  (set M.counts {})
  (set M.sample-count 0)
  (set M.dropped-samples 0)
  (set M.wall-gaps [])
  (set M.dropped-wall-gaps 0)
  (set M.marks [])
  (set M.spans [])
  (set M.dropped-spans 0)
  (set M.counters {})
  (set M.counter-count 0)
  (set M.dropped-counters 0)
  (set M.started-wall nil)
  (set M.started-cpu nil)
  (set M.stopped-wall nil)
  (set M.stopped-cpu nil)
  (set M.threads {})
  (set M.thread-count 0)
  (set M.thread-refs (setmetatable {} {:__mode :v})))

(fn normalize-source [source]
  (let [s (or source "?")]
    (if (= (string.sub s 1 1) "@") (string.sub s 2) s)))

(fn frame-key [info]
  (let [source (normalize-source info.source)
        line (or info.linedefined 0)
        name (or info.name "<anonymous>")
        what (or info.what "?")
        current (if (= M.mode :lines) (or info.currentline 0) 0)]
    (table.concat [source (tostring line) name what (tostring current)] "\31")))

(fn frame-name [info]
  (let [source (normalize-source info.source)
        line (or info.linedefined 0)
        current (if (= M.mode :lines) (or info.currentline 0) nil)
        name (or info.name
                 (if (= info.what :main) "<main>" "<anonymous>"))]
    (if current
        (string.format "%s (%s:%d @ %d)" name source line current)
        (string.format "%s (%s:%d)" name source line))))

(fn intern-frame! [info]
  (let [key (frame-key info)
        known (. M.frame-ids key)]
    (if known
        known
        (if (>= (length M.frames) M.max-frames)
            nil
            (let [id (+ (length M.frames) 1)]
              (table.insert M.frames
                {:name (frame-name info)
                 :file (normalize-source info.source)
                 :line (or info.linedefined 0)
                 :kind (or info.what "?")})
              (tset M.frame-ids key id)
              id)))))

(fn capture-stack! []
  (let [leaf-first []]
    ;; capture-stack! -> sample-hook -> generation wrapper -> interrupted code
    (var level 4)
    (var done? false)
    (var overflow? false)
    (var depth 0)
    (while (and (not done?) (< depth M.max-depth))
      (let [info (debug.getinfo level "Sln")]
        (if (not info)
            (set done? true)
            (let [id (intern-frame! info)]
              (if id
                  (table.insert leaf-first id)
                  (do (set overflow? true) (set done? true))))))
      (set level (+ level 1))
      (set depth (+ depth 1)))
    ;; If the next frame exists, max-depth truncated the root side. Drop the
    ;; sample rather than inventing a false root and merging unrelated stacks.
    (when (and (not done?) (debug.getinfo level "S"))
      (set overflow? true))
    (when (not overflow?)
      (let [root-first []]
        (for [i (length leaf-first) 1 -1]
          (table.insert root-first (. leaf-first i)))
        root-first))))

(fn intern-stack! [stack thread-id]
  (when (> (length stack) 0)
    ;; A stack belongs to one stable coroutine label so exports can offer
    ;; separate profiles as well as a merged profile without guessing later.
    (let [key (.. (tostring thread-id) "\30" (table.concat stack ","))
          known (. M.stack-ids key)]
      (if known
          known
          (when (< (length M.stacks) M.max-stacks)
            (let [id (+ (length M.stacks) 1)]
              (table.insert M.stacks stack)
              (tset M.stack-threads id thread-id)
              (tset M.stack-ids key id)
              id))))))

(fn remember-thread! [thread label]
  (let [key (tostring thread)
        known (. M.threads key)]
    (if known
        known.id
        (when (< M.thread-count M.max-threads)
          (let [id (.. "co-" (tostring (+ M.thread-count 1)))]
            (tset M.threads key {:id id :label label})
            (tset M.thread-refs key thread)
            (set M.thread-count (+ M.thread-count 1))
            id)))))

(fn sample-hook []
  (let [(thread main?) (coroutine.running)
        thread-id (or (remember-thread! thread (if main? "main" "coroutine")) "overflow")
        stack (capture-stack!)
        id (and stack (intern-stack! stack thread-id))]
    (if id
        (do
          (tset M.counts id (+ (or (. M.counts id) 0) 1))
          (set M.sample-count (+ M.sample-count 1)))
        (set M.dropped-samples (+ M.dropped-samples 1)))))

;; Public capture seam for known scheduler/TUI boundaries.  It deliberately
;; records only measured intervals; it never turns a missing Lua sample into a
;; fabricated Lua attribution.
(fn M.record-wall-gap! [gap]
  (when (and M.enabled? (>= (or gap.wall-ms 0) M.wall-gap-ms))
    (if (< (length M.wall-gaps) M.max-wall-gaps)
        (table.insert M.wall-gaps gap)
        (set M.dropped-wall-gaps (+ M.dropped-wall-gaps 1))))
  true)

(fn M.span-begin! [name ?metadata]
  ;; Store raw, low-cardinality annotation data only; activity.fnl is the
  ;; reloadable convenience layer, while this persistent module owns records.
  (if (not M.enabled?)
      nil
      (if (>= (length M.spans) M.max-spans)
          (do (set M.dropped-spans (+ M.dropped-spans 1)) nil)
          (let [token (+ (length M.spans) 1)]
            (table.insert M.spans {:name (tostring name)
                                   :metadata (or ?metadata {})
                                   :started-wall-ms (clock.monotonic-ms)
                                   :started-cpu-seconds (os.clock)
                                   :finished? false})
            token))))

(fn M.span-end! [token]
  (let [span (. M.spans token)]
    (when (and span (not span.finished?))
      (let [wall (clock.monotonic-ms)
            cpu (os.clock)]
        (tset span :finished? true)
        (tset span :ended-wall-ms wall)
        (tset span :elapsed-wall-ms (- wall span.started-wall-ms))
        (tset span :elapsed-cpu-ms (* 1000 (- cpu span.started-cpu-seconds)))
        true))))

(fn M.counter-add! [name ?amount]
  (when M.enabled?
    (let [key (tostring name)
          known (. M.counters key)]
      (if known
          (tset M.counters key (+ known (or ?amount 1)))
          (if (>= M.counter-count M.max-counters)
              (set M.dropped-counters (+ M.dropped-counters 1))
              (do
                (tset M.counters key (or ?amount 1))
                (set M.counter-count (+ M.counter-count 1)))))))
  true)

(fn M.mark! [name]
  ;; A mark has capture-relative meaning only while a capture has a start time.
  ;; Returning false keeps callers from claiming that an idle mark was saved.
  (if (and M.enabled? M.started-wall)
      (if (< (length M.marks) M.max-marks)
          (do
            (table.insert M.marks {:name (tostring name)
                                   :wall-ms (- (clock.monotonic-ms) M.started-wall)})
            true)
          false)
      false))

(fn valid-period? [period]
  (and (= (type period) :number)
       (= period (math.floor period))
       (>= period 100)))

(fn clear-hook-from-thread! [thread hook]
  (let [(ok? installed) (pcall debug.gethook thread)]
    (when (and ok? (= installed hook))
      (pcall debug.sethook thread))))

(fn M.start! [opts]
  (when M.enabled? (M.stop!))
  (let [period (or opts.period 25000)
        mode (or opts.mode :functions)
        (existing _mask _count) (debug.gethook)]
    (when existing
      (error "cannot start profiler while another debug hook is active"))
    (when (not (valid-period? period))
      (error "profile period must be an integer of at least 100"))
    (when (not (or (= mode :functions) (= mode :lines)))
      (error "profile mode must be functions or lines"))
    (clear-capture!)
    (set M.period period)
    (set M.mode mode)
    (set M.max-frames (or opts.max-frames 20000))
    (set M.max-stacks (or opts.max-stacks 50000))
    (set M.max-depth (or opts.max-depth 128))
    (set M.max-threads (or opts.max-threads 1024))
    (set M.max-wall-gaps (or opts.max-wall-gaps 2000))
    (set M.max-marks (or opts.max-marks 200))
    (set M.max-spans (or opts.max-spans 2000))
    (set M.max-counters (or opts.max-counters 64))
    (set M.wall-gap-ms (or opts.wall-gap-ms 25))
    (set M.started-wall (clock.monotonic-ms))
    (set M.started-cpu (os.clock))
    (set M.generation (+ M.generation 1))
    (let [generation M.generation
          hook (fn []
                 (if (and M.enabled? (= generation M.generation))
                     (do
                       ;; Keep this wrapper frame present: capture-stack! skips
                       ;; it explicitly, and a tail call would shift levels.
                       (sample-hook)
                       nil)
                     ;; A child beyond the retained-thread cap, or one that did
                     ;; not run before stop, removes its stale hook lazily.
                     (debug.sethook)))]
      (set M.hook hook)
      (set M.enabled? true)
      (let [(thread main?) (coroutine.running)]
        (remember-thread! thread (if main? "main" "command")))
      (coroutines.register-inheritable-hook!
        hook #(remember-thread! $1 "coroutine"))
      (debug.sethook hook "" M.period))
    true))

(fn M.stop! []
  (when M.enabled?
    (let [hook M.hook
          (installed _mask _count) (debug.gethook)]
      ;; Invalidate untracked inherited closures before clearing tracked ones.
      (set M.enabled? false)
      (set M.generation (+ M.generation 1))
      (coroutines.unregister-inheritable-hook! hook)
      (when (= installed hook) (debug.sethook))
      (each [_ thread (pairs M.thread-refs)]
        (clear-hook-from-thread! thread hook)))
    (set M.stopped-wall (clock.monotonic-ms))
    (set M.stopped-cpu (os.clock)))
  true)

(fn M.reset! []
  (M.stop!)
  (clear-capture!)
  true)

(fn M.elapsed-wall-ms []
  (if M.started-wall
      (- (or M.stopped-wall (clock.monotonic-ms)) M.started-wall)
      0))

(fn M.elapsed-cpu []
  (if M.started-cpu
      (- (or M.stopped-cpu (os.clock)) M.started-cpu)
      0))

M
