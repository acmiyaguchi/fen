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
;; FILE* mid-session. Reloadable `fen.util.log` also stores its structured
;; recent-record fields and the active level threshold on this table so
;; warnings and a host-set level survive behavior reloads.

(local M {})

(set M.handle nil)
;; Active numeric log threshold. nil until fen.util.log initializes it from
;; FEN_LOG (the CLI-host default) or a host calls log.set-level!. Held here
;; so a host-injected level survives /reload of fen.util.log.
(set M.level nil)
;; Optional fallback writer for lines emitted while no file sink is open.
;; nil means "use io.stderr when it exists" (the CLI-host default). An
;; embedded host without stderr can set this to route the fallback
;; elsewhere; the in-memory recent ring holds the line regardless.
(set M.fallback nil)
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

;; @doc fen.util.log_sink.write-fallback
;; kind: function
;; signature: (write-fallback line) -> nil
;; summary: Emit line when no file sink is active. Uses the injected M.fallback writer when set, otherwise io.stderr when it exists; on a host with neither the line survives only in the recent ring.
;; tags: util logging sink
(fn M.write-fallback [line]
  (if M.fallback
      (M.fallback line)
      (when io.stderr (io.stderr:write line))))

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
