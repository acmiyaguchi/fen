;; Persistent statistical profiler capture state. Not reloadable.
;;
;; The debug hook and bounded capture data live here so a recording survives
;; /reload. Commands, formatting, and export remain reloadable siblings.

(local coroutines (require :fen.util.coroutines))

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
   :counts {}
   :sample-count 0
   :dropped-samples 0
   :started-wall nil
   :started-cpu nil
   :stopped-wall nil
   :stopped-cpu nil
   :threads {}
   :thread-count 0
   :thread-refs (setmetatable {} {:__mode :v})
   :generation 0
   :hook nil})

(fn clear-capture! []
  (set M.frames [])
  (set M.frame-ids {})
  (set M.stacks [])
  (set M.stack-ids {})
  (set M.counts {})
  (set M.sample-count 0)
  (set M.dropped-samples 0)
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

(fn intern-stack! [stack]
  (when (> (length stack) 0)
    (let [key (table.concat stack ",")
          known (. M.stack-ids key)]
      (if known
          known
          (when (< (length M.stacks) M.max-stacks)
            (let [id (+ (length M.stacks) 1)]
              (table.insert M.stacks stack)
              (tset M.stack-ids key id)
              id))))))

(fn remember-thread! [thread label]
  (let [key (tostring thread)]
    (when (and (not (. M.threads key)) (< M.thread-count M.max-threads))
      (tset M.threads key label)
      (tset M.thread-refs key thread)
      (set M.thread-count (+ M.thread-count 1)))))

(fn sample-hook []
  (let [stack (capture-stack!)
        id (and stack (intern-stack! stack))]
    (if id
        (do
          (tset M.counts id (+ (or (. M.counts id) 0) 1))
          (set M.sample-count (+ M.sample-count 1)))
        (set M.dropped-samples (+ M.dropped-samples 1)))))

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
    (set M.started-wall (os.time))
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
    (set M.stopped-wall (os.time))
    (set M.stopped-cpu (os.clock)))
  true)

(fn M.reset! []
  (M.stop!)
  (clear-capture!)
  true)

(fn M.elapsed-cpu []
  (if M.started-cpu
      (- (or M.stopped-cpu (os.clock)) M.started-cpu)
      0))

M
