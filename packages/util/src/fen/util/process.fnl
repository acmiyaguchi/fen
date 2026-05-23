;; Cooperative process I/O helpers.
;;
;; Lua's io.popen returns a blocking FILE*; pipe:read :*a waits until the
;; child closes its end, freezing the agent coroutine for the entire
;; command. This module sets the underlying fd to O_NONBLOCK and reads
;; in chunks, calling yield-fn on EAGAIN so the TUI loop keeps ticking.
;;
;; The native fen_process module also exposes a small POSIX subprocess
;; surface used by run-captured. That helper owns the child PID/process
;; group directly so timeouts and cancellation do not depend on timeout(1)
;; or pclose() waiting for inherited pipe handles.

(local native (require :fen_process))
(local path (require :fen.util.path))

(local CHUNK-SIZE 4096)
(local DEFAULT-MAX-LINES 2000)
(local DEFAULT-MAX-BYTES (* 50 1024))
(local DEFAULT-IDLE-MS 10)
(local DEFAULT-KILL-GRACE-MS 200)
(local DEFAULT-POST-EXIT-DRAIN-MS 150)
(local MAX-READS-BEFORE-YIELD 16)

(fn set-nonblock! [fd]
  (native.set_nonblock fd))

;; @doc fen.util.process.read-pipe-coop
;; kind: function
;; signature: (read-pipe-coop pipe yield-fn) -> string
;; summary: Drain a popen pipe in nonblocking chunks, yielding on EAGAIN so cooperative tool execution keeps the UI responsive.
;; tags: util process cooperative
(fn read-pipe-coop [pipe yield-fn]
  "Drain a popen pipe to a string, yielding via yield-fn whenever the
   underlying fd would block. Returns the concatenated output. Read
   errors other than EAGAIN end the loop early — pipe:close() in the
   caller surfaces the exit code."
  (let [fd (native.fileno pipe)]
    (set-nonblock! fd)
    (let [chunks []]
      (var done? false)
      (var reads-since-yield 0)
      (while (not done?)
        (let [(data _err eno) (native.read fd CHUNK-SIZE)]
          (if (= data "")
              ;; EOF — child closed its write end.
              (set done? true)
              data
              (do
                (table.insert chunks data)
                (set reads-since-yield (+ reads-since-yield 1))
                (when (and yield-fn (>= reads-since-yield MAX-READS-BEFORE-YIELD))
                  (set reads-since-yield 0)
                  (yield-fn)))
              (or (= eno native.EAGAIN) (= eno native.EWOULDBLOCK))
              ;; No data available right now; let the TUI tick.
              (when yield-fn (yield-fn))
              ;; Other read error — give up and let the caller close
              ;; the pipe to surface the exit code.
              (set done? true))))
      (table.concat chunks))))

;; @doc fen.util.process.read-pipe-close
;; kind: function
;; signature: (read-pipe-close pipe yield-fn?) -> string
;; summary: Drain and close a popen pipe, guaranteeing close runs even when cooperative cancellation raises through yield-fn.
;; tags: util process cooperative popen
(fn read-pipe-close [pipe ?yield-fn]
  "Drain a popen pipe and close it in all paths. Cooperative callers can
   raise through yield-fn; this helper still closes the FILE* before
   rethrowing so long-lived shell children do not keep pipe resources open."
  (let [(ok? result) (xpcall
                       (fn []
                         (if ?yield-fn
                             (read-pipe-coop pipe ?yield-fn)
                             (or (pipe:read :*a) "")))
                       debug.traceback)]
    (pipe:close)
    (if ok? result (error result))))

(fn eagain? [eno]
  (or (= eno native.EAGAIN)
      (and native.EWOULDBLOCK (= eno native.EWOULDBLOCK))))

(fn monotonic-ms []
  (let [(ms err) (native.monotonic_ms)]
    (if ms ms (error (.. "monotonic_ms failed: " (tostring err))))))

(fn sleep-ms [ms]
  (native.sleep_ms ms))

(fn count-newlines [s]
  (var n 0)
  (each [_ (string.gmatch (or s "") "\n")]
    (set n (+ n 1)))
  n)

(fn count-lines-final [bytes newlines last-char]
  (if (= bytes 0) 0
      (= last-char "\n") newlines
      (+ newlines 1)))

(local shellquote path.shell-quote)

(fn home []
  (or (os.getenv :HOME) "/tmp"))

(fn output-dir []
  (let [xdg (os.getenv :XDG_STATE_HOME)]
    (if (and xdg (not= xdg ""))
        (.. xdg "/fen/tool-output")
        (.. (home) "/.local/state/fen/tool-output"))))

(fn spill-id []
  (math.randomseed (+ (os.time) (math.floor (* (os.clock) 1000000))))
  (let [parts []]
    (for [_ 1 8]
      (table.insert parts (string.format "%x" (math.random 0 15))))
    (table.concat parts)))

(fn open-spill-file []
  (let [dir (output-dir)
        _ (os.execute (.. "mkdir -p " (shellquote dir)))
        ts (os.date "!%Y%m%dT%H%M%S")
        path (.. dir "/" ts "_process_" (spill-id) ".log")
        (f err) (io.open path :w)]
    (if f (values f path) (values nil nil err))))

(fn trim-tail [s max-bytes max-lines]
  (var out (or s ""))
  (when (and max-bytes (> max-bytes 0) (> (length out) max-bytes))
    (set out (string.sub out (- max-bytes))))
  (when (and max-lines (> max-lines 0))
    (let [lines []]
      (each [line (string.gmatch (.. out "\n") "([^\n]*)\n")]
        (table.insert lines line))
      (when (> (length lines) max-lines)
        (let [kept []
              start (+ (- (length lines) max-lines) 1)]
          (for [i start (length lines)]
            (table.insert kept (. lines i)))
          (set out (table.concat kept "\n"))))))
  out)

(fn error-from-native [name err eno]
  (.. name " failed: " (tostring err) " (errno " (tostring eno) ")"))

;; @doc fen.util.process.run-captured
;; kind: function
;; signature: (run-captured opts yield-fn?) -> table
;; summary: Run a shell command with cooperative output capture, timeout/cancel cleanup, bounded inline output, and optional full-output spill file.
;; tags: util process subprocess timeout cooperative
(fn run-captured [opts ?yield-fn]
  "Run opts.cmd via /bin/sh -c with merged stdout/stderr. The child runs in
   its own process group so timeout and cancellation can terminate the whole
   tree. Output is captured incrementally; :output is the bounded inline tail
   and :full-path is set when :spill? opened a full-output log."
  (let [opts (or opts {})
        cmd (or opts.cmd (?. opts :cmd))
        cwd (or opts.cwd (?. opts :cwd))]
    (when (or (not cmd) (= cmd ""))
      (error "run-captured requires :cmd"))
    (let [max-lines (or (?. opts :max-lines) DEFAULT-MAX-LINES)
          max-bytes (or (?. opts :max-bytes) DEFAULT-MAX-BYTES)
          tail-soft-cap (math.max CHUNK-SIZE (* max-bytes 2))
          timeout-seconds (?. opts :timeout-seconds)
          timeout-ms (and timeout-seconds (* timeout-seconds 1000))
          kill-grace-ms (or (?. opts :kill-grace-ms) DEFAULT-KILL-GRACE-MS)
          post-exit-drain-ms (or (?. opts :post-exit-drain-ms)
                                  DEFAULT-POST-EXIT-DRAIN-MS)
          (child spawn-err spawn-eno) (native.spawn_shell cmd cwd)]
      (when (not child)
        (error (error-from-native :spawn_shell spawn-err spawn-eno)))
      (let [pid child.pid
            fd child.fd
            start-ms (monotonic-ms)
            deadline-ms (and timeout-ms (+ start-ms timeout-ms))
            spill-requested? (not (not (?. opts :spill?)))
            always-spill? (not (not (?. opts :always-spill?)))
            (initial-spill-file initial-spill-path) (if always-spill?
                                                       (open-spill-file)
                                                       (values nil nil))]
        (var fd-open? true)
        (var spill-file initial-spill-file)
        (var spill-path initial-spill-path)
        (var spill-open? (not (not spill-file)))
        (var spill-disabled? false)
        (var full-before-spill (if (and spill-requested? (not spill-open?)) "" nil))
        (var eof? false)
        (var reaped? false)
        (var exit-code nil)
        (var signal nil)
        (var timed-out? false)
        (var post-exit-deadline nil)
        (var total-bytes 0)
        (var total-newlines 0)
        (var chunks 0)
        (var last-char nil)
        (var tail "")

        (fn close-fd! []
          (when fd-open?
            (set fd-open? false)
            (native.close_fd fd)))

        (fn close-spill! []
          (when spill-open?
            (set spill-open? false)
            (spill-file:close)))

        (fn append-output! [chunk]
          (set chunks (+ chunks 1))
          (set total-bytes (+ total-bytes (length chunk)))
          (set total-newlines (+ total-newlines (count-newlines chunk)))
          (set last-char (string.sub chunk -1))
          (if spill-open?
              (spill-file:write chunk)
              (and full-before-spill (not spill-disabled?))
              (set full-before-spill (.. full-before-spill chunk)))
          (set tail (.. tail chunk))
          (when (> (length tail) tail-soft-cap)
            (set tail (string.sub tail (- tail-soft-cap))))
          (let [total-lines (count-lines-final total-bytes total-newlines last-char)]
            (when (and spill-requested? (not spill-open?) (not spill-disabled?)
                       (or (> total-bytes max-bytes) (> total-lines max-lines)))
              (let [(f path) (open-spill-file)]
                (if f
                    (do
                      (set spill-file f)
                      (set spill-path path)
                      (set spill-open? true)
                      (spill-file:write (or full-before-spill ""))
                      (set full-before-spill nil))
                    ;; If spilling is unavailable (for example a full or
                    ;; unwritable state dir), fall back to bounded tail-only
                    ;; capture rather than keeping an unbounded pre-spill
                    ;; buffer in memory.
                    (do
                      (set spill-disabled? true)
                      (set full-before-spill nil)))))))

        (fn drain! []
          (var saw-data? false)
          (var done? false)
          (var reads 0)
          (while (and fd-open? (not done?))
            (let [(data err eno) (native.read fd CHUNK-SIZE)]
              (if (= data "")
                  (do (set eof? true)
                      (set done? true))
                  data
                  (do (set saw-data? true)
                      (append-output! data)
                      (set reads (+ reads 1))
                      ;; A child that is constantly producing output can keep
                      ;; the fd readable for a long burst. Cap one drain pass
                      ;; so cooperative callers get back to the presenter even
                      ;; before EAGAIN.
                      (when (>= reads MAX-READS-BEFORE-YIELD)
                        (set done? true)))
                  (eagain? eno)
                  (set done? true)
                  (error (error-from-native :read err eno)))))
          saw-data?)

        (fn poll-child! [nohang?]
          (when (not reaped?)
            (let [(ok kind value) (native.wait_pid pid nohang?)]
              (if (not ok)
                  (error (error-from-native :wait_pid kind value))
                  (= kind "running")
                  nil
                  (do (set reaped? true)
                      (if (= kind "exit")
                          (set exit-code value)
                          (= kind "signal")
                          (set signal value)
                          ;; wait_pid should only produce this for unusual
                          ;; raw wait statuses; avoid misreporting it as a
                          ;; signal.
                          (set exit-code value))))))
          reaped?)

        (fn idle! []
          (if ?yield-fn
              (?yield-fn)
              (sleep-ms DEFAULT-IDLE-MS)))

        (fn wait-with-grace! [grace-ms allow-yield?]
          (let [until-ms (+ (monotonic-ms) (or grace-ms 0))]
            (while (and (not reaped?) (< (monotonic-ms) until-ms))
              (drain!)
              (poll-child! true)
              (when (not reaped?)
                (if (and allow-yield? ?yield-fn)
                    (?yield-fn)
                    (sleep-ms DEFAULT-IDLE-MS))))))

        (fn terminate! [first-signal grace-ms allow-yield?]
          (when (not reaped?)
            (native.kill_process_group pid first-signal)
            (wait-with-grace! grace-ms allow-yield?)
            (when (not reaped?)
              (native.kill_process_group pid native.SIGKILL)
              (wait-with-grace! 1000 false))
            (when (not reaped?)
              (poll-child! false))))

        (fn finish-output []
          (let [total-lines (count-lines-final total-bytes total-newlines last-char)
                output (trim-tail tail max-bytes max-lines)
                output-lines (count-lines-final (length output)
                                                (count-newlines output)
                                                (and (> (length output) 0)
                                                     (string.sub output -1)))
                truncated? (or (> total-bytes (length output))
                               (> total-lines output-lines))
                duration-ms (- (monotonic-ms) start-ms)]
            {:exit-code exit-code
             :signal signal
             :timed-out? timed-out?
             :cancelled? false
             :duration-ms duration-ms
             :duration-seconds (/ duration-ms 1000)
             :output output
             :full-path spill-path
             :full-output-path spill-path
             :truncated? truncated?
             :stats {:bytes-read total-bytes
                     :total-bytes total-bytes
                     :lines-read total-lines
                     :total-lines total-lines
                     :chunks chunks}}))

        (let [(ok? result-or-err)
              (pcall
                (fn []
                  (var done? false)
                  (while (not done?)
                    (drain!)
                    (poll-child! true)
                    (let [now (monotonic-ms)]
                      (when (and deadline-ms (not reaped?) (>= now deadline-ms))
                        (set timed-out? true)
                        (terminate! native.SIGTERM kill-grace-ms true))
                      (when (and reaped? (not post-exit-deadline))
                        (set post-exit-deadline (+ now post-exit-drain-ms)))
                      (when (or (and reaped? eof?)
                                (and post-exit-deadline
                                     (>= now post-exit-deadline)))
                        (set done? true)))
                    (when (not done?)
                      (idle!)))
                  (drain!)
                  (close-fd!)
                  (close-spill!)
                  (finish-output)))]
          (if ok?
              result-or-err
              (do
                ;; A yield-fn cancellation or unexpected read error must not
                ;; leave a live child, open fd, or unclosed spill file.
                (terminate! native.SIGKILL 0 false)
                (close-fd!)
                (close-spill!)
                (error result-or-err))))))))

{: read-pipe-coop
 : read-pipe-close
 : run-captured
 : monotonic-ms
 : sleep-ms}
