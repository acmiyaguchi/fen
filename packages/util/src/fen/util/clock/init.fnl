;; Monotonic clock/sleep in their own module so the agent hot path never pulls in the subprocess surface.

;; Backend resolved once at load; /reload re-requires it; tests pre-load package.loaded first.
(local backend (require :fen.util.clock.backend))

(local M {})

;; @doc fen.util.clock.monotonic-ms
;; kind: function
;; signature: (monotonic-ms) -> number
;; summary: Return a monotonic clock reading in milliseconds via the injectable clock backend.
;; tags: util clock time monotonic
(fn M.monotonic-ms []
  (backend.monotonic-ms))

;; @doc fen.util.clock.sleep-ms
;; kind: function
;; signature: (sleep-ms ms) -> nil
;; summary: Sleep for the given number of milliseconds via the injectable clock backend.
;; tags: util clock time sleep
(fn M.sleep-ms [ms]
  (backend.sleep-ms ms))

M
