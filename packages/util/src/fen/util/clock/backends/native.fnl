;; Default backend wrapping fen_process monotonic_ms/sleep_ms.

(local native (require :fen_process))

(local M {})

;; @doc fen.util.clock.backends.native.monotonic-ms
;; kind: function
;; signature: (monotonic-ms) -> number
;; summary: Return a monotonic millisecond reading from the fen_process native clock, erroring if it is unavailable.
;; tags: util clock time monotonic native
(fn M.monotonic-ms []
  (let [(ms err) (native.monotonic_ms)]
    (if ms ms (error (.. "monotonic_ms failed: " (tostring err))))))

;; @doc fen.util.clock.backends.native.sleep-ms
;; kind: function
;; signature: (sleep-ms ms) -> nil
;; summary: Sleep for ms milliseconds using the fen_process native sleep.
;; tags: util clock time sleep native
(fn M.sleep-ms [ms]
  (native.sleep_ms ms))

M
