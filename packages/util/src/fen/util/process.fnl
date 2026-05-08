;; Cooperative process I/O helpers.
;;
;; Lua's io.popen returns a blocking FILE*; pipe:read :*a waits until the
;; child closes its end, freezing the agent coroutine for the entire
;; command. This module sets the underlying fd to O_NONBLOCK and reads
;; in chunks, calling yield-fn on EAGAIN so the TUI loop keeps ticking.
;;
;; Lazy-required by tools.run-bash-coop — print mode and tests that don't
;; touch the coop bash path don't pull in the native helper.

(local native (require :fen_process))

(local CHUNK-SIZE 4096)

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
      (while (not done?)
        (let [(data _err eno) (native.read fd CHUNK-SIZE)]
          (if (= data "")
              ;; EOF — child closed its write end.
              (set done? true)
              data
              (table.insert chunks data)
              (or (= eno native.EAGAIN) (= eno native.EWOULDBLOCK))
              ;; No data available right now; let the TUI tick.
              (when yield-fn (yield-fn))
              ;; Other read error — give up and let the caller close
              ;; the pipe to surface the exit code.
              (set done? true))))
      (table.concat chunks))))

{: read-pipe-coop}
