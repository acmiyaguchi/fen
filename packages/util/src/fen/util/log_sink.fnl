;; Non-reloadable holder for the fen log file handle; /reload must not drop the open FILE*.
;; Single owner (the active presenter); fen.util.log also stores level/recent state here to survive reloads.

(local M {})

(set M.handle nil)
;; nil until fen.util.log initializes from FEN_LOG or a host sets it; held here to survive /reload.
(set M.level nil)
;; Fallback writer when no file sink is open; nil means io.stderr-when-present (embedded hosts inject).
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
