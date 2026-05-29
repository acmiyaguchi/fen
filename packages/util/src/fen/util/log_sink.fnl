;; Non-reloadable holder for the optional fen log file handle.
;;
;; Lives in util (not extensions) because fen.util.log routes through it
;; without taking a dependency on extension code.
;;
;; Single-owner: the active presenter (TUI today) calls open! on init and
;; close! on shutdown. The sink intentionally has no refcount; if a second
;; owner ever needs to redirect, add the bookkeeping then. Cross-presenter
;; coordination today is the caller's job.
;;
;; Kept out of any RELOADABLE list — `/reload` must not drop the open
;; FILE* mid-session.

(local M {})

(set M.handle nil)

;; @doc fen.util.log_sink.open!
;; kind: function
;; signature: (open! path) -> boolean,?string
;; summary: Open path in append mode as the active log sink, closing any prior handle. Returns ok?, err.
;; tags: util logging sink
(fn M.open! [path]
  (when M.handle (pcall #(M.handle:close)))
  (set M.handle nil)
  (let [(f err) (io.open path :a)]
    (if f
        (do (set M.handle f) (values true nil))
        (values false err))))

;; @doc fen.util.log_sink.close!
;; kind: function
;; signature: (close!) -> nil
;; summary: Close and clear the active log sink handle, returning log routing to stderr.
;; tags: util logging sink
(fn M.close! []
  (when M.handle
    (pcall #(M.handle:close)))
  (set M.handle nil))

;; @doc fen.util.log_sink.active?
;; kind: function
;; signature: (active?) -> boolean
;; summary: True when a file sink is currently open and write-line will land in the file.
;; tags: util logging sink
(fn M.active? []
  (not= M.handle nil))

;; @doc fen.util.log_sink.write-line
;; kind: function
;; signature: (write-line s) -> boolean,?string
;; summary: Append s plus a newline to the active sink and flush. Returns true on success; on write failure clears the handle (so callers can fall back to stderr) and returns false plus the error. No-op true when the sink is inactive.
;; tags: util logging sink
(fn try-write [s]
  "Lua FILE:write/flush return (nil, errmsg) on disk-full / EIO without
   throwing — pcall alone would miss them. A closed handle, by contrast,
   throws. Cover both."
  (let [(ok? a b) (pcall (fn []
                           (let [(w w-err) (M.handle:write s "\n")]
                             (if (not w)
                                 (values false w-err)
                                 (let [(f f-err) (M.handle:flush)]
                                   (if (not f)
                                       (values false f-err)
                                       (values true nil)))))))]
    (if ok? (values a b) (values false a))))

(fn M.write-line [s]
  (if M.handle
      (let [(ok? err) (try-write s)]
        (if ok?
            (values true nil)
            (do (pcall #(M.handle:close))
                (set M.handle nil)
                (values false (or err "io failure")))))
      (values true nil)))

M
