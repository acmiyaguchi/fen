;; Cooperative process I/O: fds set O_NONBLOCK, chunked reads, yield-fn on EAGAIN so a slow child never blocks the TUI.
;; Subprocess surface routes through the injectable fen.util.process.backend seam (#472); clock lives in fen.util.clock.
;; Containment: children run in their own session and timeouts signal the process group; a descendant that calls
;; setsid() itself escapes and can outlive the advertised timeout (whole-tree kill needs the sandbox, #19).

(local backend (require :fen.util.process.backend))
(local clock (require :fen.util.clock))
(local path (require :fen.util.path))
(local random (require :fen.util.random))

(local CHUNK-SIZE 4096)
(local DEFAULT-MAX-LINES 2000)
(local DEFAULT-MAX-BYTES (* 50 1024))
(local DEFAULT-IDLE-MS 10)
(local DEFAULT-KILL-GRACE-MS 200)
(local DEFAULT-POST-EXIT-DRAIN-MS 150)
(local MAX-READS-BEFORE-YIELD 16)

(fn set-nonblock! [fd]
  (backend.set_nonblock fd))

(fn read-pipe-coop [pipe yield-fn]
  "Drain a popen pipe to a string, yielding via yield-fn whenever the
   underlying fd would block. Returns the concatenated output. Read
   errors other than EAGAIN end the loop early — pipe:close() in the
   caller surfaces the exit code."
  (let [fd (backend.fileno pipe)]
    (set-nonblock! fd)
    (let [chunks []]
      (var done? false)
      (var reads-since-yield 0)
      (while (not done?)
        (let [(data _err eno) (backend.read fd CHUNK-SIZE)]
          (if (= data "")
              (set done? true)
              data
              (do
                (table.insert chunks data)
                (set reads-since-yield (+ reads-since-yield 1))
                (when (and yield-fn (>= reads-since-yield MAX-READS-BEFORE-YIELD))
                  (set reads-since-yield 0)
                  (yield-fn)))
              (or (= eno backend.EAGAIN) (= eno backend.EWOULDBLOCK))
              ;; EAGAIN: idle briefly so a slow child doesn't pin a core, then let the TUI tick.
              (do
                (clock.sleep-ms DEFAULT-IDLE-MS)
                (when yield-fn (yield-fn)))
              (set done? true))))
      (table.concat chunks))))

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
  (or (= eno backend.EAGAIN)
      (and backend.EWOULDBLOCK (= eno backend.EWOULDBLOCK))))

(fn setenv! [name value]
  "Set an environment variable for this process, or unset it when value is nil."
  (let [(ok? err eno) (backend.setenv name value)]
    (if ok?
        ok?
        (error (.. "setenv " (tostring name) " failed: " (tostring err)
                   " (errno " (tostring eno) ")")))))

(fn count-newlines [s]
  (var n 0)
  (each [_ (string.gmatch (or s "") "\n")]
    (set n (+ n 1)))
  n)

(fn count-lines-final [bytes newlines last-char]
  (if (= bytes 0) 0
      (= last-char "\n") newlines
      (+ newlines 1)))

(fn output-dir []
  (.. (path.state-dir :fen) "/tool-output"))

(fn spill-id []
  ;; Spill must never raise mid-tool: fall back to a clock-derived id if the RNG backend errors.
  (let [(ok? id) (pcall (fn []
                          (let [(hex) (: (random.bytes 4) :gsub "."
                                         (fn [c] (string.format "%02x" (string.byte c))))]
                            hex)))]
    (if ok? id (string.format "%08x" (% (math.floor (clock.monotonic-ms)) 0x100000000)))))

(fn open-spill-file []
  (let [dir (output-dir)
        _ (path.ensure-dir! dir)
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

(fn start-captured [opts]
  "Start a child described by :cmd or :argv. job:resume() performs one
   bounded drain/poll/state-machine tick without waiting for child progress
   and returns done?, result. job:abort() is idempotent and signals the
   child's process group to stop; keep resuming it to reap and finish
   capture. Descendants that leave that group (for example by calling
   setsid()) are not contained -- see the containment contract at the top of
   this module."
  (let [opts (or opts {})
        cmd (?. opts :cmd)
        argv (?. opts :argv)
        cwd (?. opts :cwd)
        env (?. opts :env)]
    (when (and (or (not cmd) (= cmd "")) (not argv))
      (error "run-captured requires :cmd or :argv"))
    (let [max-lines (or (?. opts :max-lines) DEFAULT-MAX-LINES)
          max-bytes (or (?. opts :max-bytes) DEFAULT-MAX-BYTES)
          tail-soft-cap (math.max CHUNK-SIZE (* max-bytes 2))
          timeout-seconds (?. opts :timeout-seconds)
          timeout-ms (and timeout-seconds (* timeout-seconds 1000))
          kill-grace-ms (or (?. opts :kill-grace-ms) DEFAULT-KILL-GRACE-MS)
          post-exit-drain-ms (or (?. opts :post-exit-drain-ms)
                                  DEFAULT-POST-EXIT-DRAIN-MS)
          (child spawn-err spawn-eno) (if argv
                                          (backend.spawn argv cwd env)
                                          (backend.spawn_shell cmd cwd))]
      (when (not child)
        (error (error-from-native (if argv :spawn :spawn_shell)
                                  spawn-err spawn-eno)))
      (let [pid child.pid
            fd child.fd
            start-ms (clock.monotonic-ms)
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
        (var cancelled? false)
        (var term-sent? false)
        (var kill-sent? false)
        (var kill-deadline-ms nil)
        (var post-exit-deadline nil)
        (var total-bytes 0)
        (var total-newlines 0)
        (var chunks 0)
        (var last-char nil)
        (var tail "")
        (var finished-result nil)

        (fn close-fd! []
          (when fd-open?
            (set fd-open? false)
            (backend.close_fd fd)))

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
                    (do
                      (set spill-disabled? true)
                      (set full-before-spill nil)))))))

        (fn drain! []
          (var done? false)
          (var reads 0)
          (while (and fd-open? (not done?))
            (let [(data err eno) (backend.read fd CHUNK-SIZE)]
              (if (= data "")
                  (do (set eof? true) (set done? true))
                  data
                  (do
                    (append-output! data)
                    (set reads (+ reads 1))
                    (when (>= reads MAX-READS-BEFORE-YIELD)
                      (set done? true)))
                  (eagain? eno)
                  (set done? true)
                  (error (error-from-native :read err eno))))))

        (fn poll-child! []
          (when (not reaped?)
            (let [(ok kind value) (backend.wait_pid pid true)]
              (if (not ok)
                  (error (error-from-native :wait_pid kind value))
                  (= kind "running") nil
                  (do
                    (set reaped? true)
                    (if (= kind "exit")
                        (set exit-code value)
                        (= kind "signal")
                        (set signal value)
                        (set exit-code value)))))))

        (fn send-kill! []
          (when (and (not reaped?) (not kill-sent?))
            (set kill-sent? true)
            (backend.kill_process_group pid backend.SIGKILL)))

        (fn abort! []
          (when (not finished-result)
            (set cancelled? true)
            (send-kill!))
          nil)

        (fn finish-output []
          (let [total-lines (count-lines-final total-bytes total-newlines last-char)
                output (trim-tail tail max-bytes max-lines)
                output-lines (count-lines-final (length output)
                                                (count-newlines output)
                                                (and (> (length output) 0)
                                                     (string.sub output -1)))
                truncated? (or (> total-bytes (length output))
                               (> total-lines output-lines))
                duration-ms (- (clock.monotonic-ms) start-ms)]
            {:exit-code exit-code
             :signal signal
             :timed-out? timed-out?
             :cancelled? cancelled?
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

        (fn tick! []
          (drain!)
          (poll-child!)
          (let [now (clock.monotonic-ms)]
            (when (and deadline-ms (not reaped?) (not term-sent?)
                       (>= now deadline-ms))
              (set timed-out? true)
              (set term-sent? true)
              (set kill-deadline-ms (+ now kill-grace-ms))
              (backend.kill_process_group pid backend.SIGTERM))
            (when (and term-sent? (not reaped?) (not kill-sent?)
                       (>= now kill-deadline-ms))
              (send-kill!))
            (when (and reaped? (not post-exit-deadline))
              (set post-exit-deadline (+ now post-exit-drain-ms)))
            (when (or (and reaped? eof?)
                      (and post-exit-deadline (>= now post-exit-deadline)))
              (drain!)
              (close-fd!)
              (close-spill!)
              (set finished-result (finish-output))))
          (if finished-result
              (values true finished-result)
              (values false nil)))

        (fn cleanup-after-error! []
          ;; Error cleanup may wait: must not return with a live child or owned descriptors.
          (send-kill!)
          (let [until-ms (+ (clock.monotonic-ms) 1000)]
            (while (and (not reaped?) (< (clock.monotonic-ms) until-ms))
              (let [(ok?) (pcall poll-child!)]
                (when (not ok?) (set reaped? true)))
              (when (not reaped?) (clock.sleep-ms DEFAULT-IDLE-MS))))
          (close-fd!)
          (close-spill!))

        (fn resume! []
          (if finished-result
              (values true finished-result)
              (let [(ok? done? result) (pcall tick!)]
                (if ok?
                    (values done? result)
                    (do
                      (cleanup-after-error!)
                      (error done?))))))

        {:resume resume! :abort abort!}))))

(fn run-captured [opts ?yield-fn]
  "Run start-captured to completion. Without a yield function this retains the
   historical synchronous behavior by sleeping briefly between nonblocking
   ticks. Cancellation raised by yield-fn kills and reaps the child."
  (let [job (start-captured opts)
        (ok? result-or-err)
        (pcall
          (fn []
            (var result nil)
            (var done? false)
            (while (not done?)
              (let [(tick-done? tick-result) (job:resume)]
                (set done? tick-done?)
                (set result tick-result))
              (when (not done?)
                (if ?yield-fn (?yield-fn) (clock.sleep-ms DEFAULT-IDLE-MS))))
            result))]
    (if ok?
        result-or-err
        (do
          (job:abort)
          (var done? false)
          (while (not done?)
            (let [(tick-done?) (job:resume)]
              (set done? tick-done?))
            (when (not done?) (clock.sleep-ms DEFAULT-IDLE-MS)))
          (error result-or-err)))))

{: read-pipe-coop
 : read-pipe-close
 : start-captured
 : run-captured
 : setenv!}
