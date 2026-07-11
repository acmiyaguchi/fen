;; Persistent statistical profiler capture state. Not reloadable.
;;
;; The debug hook must keep one stable identity while /reload replaces profiler
;; behavior modules. Keep only bounded capture data and the hook's minimal hot
;; path here; commands, formatting, and export remain reloadable siblings.

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
   :thread-refs (setmetatable {} {:__mode :v})})

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
    (var level 2)
    (var done? false)
    (var overflow? false)
    (while (and (not done?) (<= level M.max-depth))
      (let [info (debug.getinfo level "Sln")]
        (if (not info)
            (set done? true)
            (let [id (intern-frame! info)]
              (if id
                  (table.insert leaf-first id)
                  (do (set overflow? true) (set done? true))))))
      (set level (+ level 1)))
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
  ;; Lua suppresses recursive hook calls while a hook is running. An inherited
  ;; hook may outlive a stopped capture on a coroutine that never sampled; let
  ;; its first later hook invocation remove itself instead of charging forever.
  (if (not M.enabled?)
      (debug.sethook)
      (do
        (let [(thread main?) (coroutine.running)]
          (remember-thread! thread (if main? "main" "coroutine")))
        (let [stack (capture-stack!)
              id (and stack (intern-stack! stack))]
          (if id
              (do
                (tset M.counts id (+ (or (. M.counts id) 0) 1))
                (set M.sample-count (+ M.sample-count 1)))
              (set M.dropped-samples (+ M.dropped-samples 1)))))))

(set M.hook sample-hook)

(fn M.install-thread! [thread label]
  "Install the stable hook on a known coroutine while a capture is active."
  (when (and M.enabled? thread)
    (let [(hook _mask _count) (debug.gethook thread)]
      (when (and hook (not= hook M.hook))
        (error "cannot install profiler over an existing debug hook")))
    (debug.sethook thread M.hook "" M.period)
    (remember-thread! thread (or label (tostring thread)))))

(fn M.start! [opts]
  (when M.enabled? (M.stop!))
  (let [(hook _mask _count) (debug.gethook)]
    (when (and hook (not= hook M.hook))
      (error "cannot start profiler while another debug hook is active")))
  (clear-capture!)
  (set M.period (or opts.period 25000))
  (set M.mode (or opts.mode :functions))
  (set M.max-frames (or opts.max-frames 20000))
  (set M.max-stacks (or opts.max-stacks 50000))
  (set M.max-depth (or opts.max-depth 128))
  (set M.max-threads (or opts.max-threads 1024))
  (set M.started-wall (os.time))
  (set M.started-cpu (os.clock))
  (set M.enabled? true)
  (let [(thread main?) (coroutine.running)]
    (remember-thread! thread (if main? "main" "command")))
  (debug.sethook M.hook "" M.period)
  true)

(fn M.stop! []
  (when M.enabled?
    (let [(hook _mask _count) (debug.gethook)]
      (when (= hook M.hook) (debug.sethook)))
    (each [_ thread (pairs M.thread-refs)]
      (let [(ok? hook) (pcall debug.gethook thread)]
        (when (and ok? (= hook M.hook))
          (pcall debug.sethook thread))))
    (set M.enabled? false)
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
