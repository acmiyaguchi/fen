;; Cooperative process I/O helpers.
;;
;; Lua's io.popen returns a blocking FILE*; pipe:read :*a waits until the
;; child closes its end, freezing the agent coroutine for the entire
;; command. This module sets the underlying fd to O_NONBLOCK and reads
;; in chunks, calling yield-fn on EAGAIN so the TUI loop keeps ticking.
;;
;; Lazy-required by tools.run-bash-coop — print mode and tests that don't
;; touch the coop bash path don't pull in luaposix.

(local stdio (require :posix.stdio))
(local unistd (require :posix.unistd))
(local fcntl (require :posix.fcntl))
(local errno-mod (require :posix.errno))

(local CHUNK-SIZE 4096)

(fn set-nonblock! [fd]
  (let [flags (fcntl.fcntl fd fcntl.F_GETFL)]
    (fcntl.fcntl fd fcntl.F_SETFL (bor flags fcntl.O_NONBLOCK))))

(fn read-pipe-coop [pipe yield-fn]
  "Drain a popen pipe to a string, yielding via yield-fn whenever the
   underlying fd would block. Returns the concatenated output. Read
   errors other than EAGAIN end the loop early — pipe:close() in the
   caller surfaces the exit code."
  (let [fd (stdio.fileno pipe)]
    (set-nonblock! fd)
    (let [chunks []]
      (var done? false)
      (while (not done?)
        (let [(data _err eno) (unistd.read fd CHUNK-SIZE)]
          (if (= data "")
              ;; EOF — child closed its write end.
              (set done? true)
              data
              (table.insert chunks data)
              (= eno errno-mod.EAGAIN)
              ;; No data available right now; let the TUI tick.
              (when yield-fn (yield-fn))
              ;; Other read error — give up and let the caller close
              ;; the pipe to surface the exit code.
              (set done? true))))
      (table.concat chunks))))

{: read-pipe-coop}
