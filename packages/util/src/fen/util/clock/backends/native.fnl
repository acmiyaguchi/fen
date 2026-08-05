;; Default (native) clock backend for fen.util.clock.
;;
;; Wraps the project-owned fen_process native module's monotonic_ms/sleep_ms.
;; This is the seam's default backend (see fen.util.clock.backend). Keeping the
;; fen_process behavior here means the injectable seam changes nothing about
;; default CLI behavior; a host lacking fen_process supplies its own backend
;; exposing the same surface: monotonic-ms/sleep-ms.

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
