;; Default config-storage backend for fen.core.storage.
;;
;; Keeps the exact XDG-file behavior config persistence used before the seam:
;; read via io.open (nil when the file is absent), and write via mkdir -p +
;; temp-file + os.rename with os.remove cleanup on failure, i.e. an atomic
;; replace. This is the seam's default backend (see fen.core.storage.backend).
;; A host that backs config with its own persistence ships a different backend
;; module.
;;
;; Mirrors fen.util.path.backend / fen.core.extensions.loader.discover.backend:
;; one mechanism, the injectable backend, with the current POSIX file behavior
;; kept as the default. Callers resolve the document location through
;; fen.util.path (XDG), so this backend only touches bytes at a given path.

(local path (require :fen.util.path))

;; @doc fen.core.storage.backends.default.read
;; kind: function
;; signature: (read p) -> string|nil
;; summary: Read a file's full contents via io.open, returning nil silently when the file is missing.
;; tags: storage config io backend
(fn read [p]
  "Read entire file or return nil silently if missing. Config documents are
   optional and a missing file is the common case."
  (let [(f _) (io.open p :r)]
    (when f
      (let [s (f:read :*a)]
        (f:close)
        s))))

;; @doc fen.core.storage.backends.default.write!
;; kind: function
;; signature: (write! p content) -> nil
;; summary: Atomically write content to a file via mkdir -p + temp-file + os.rename, removing the temp file if the rename fails.
;; tags: storage config io backend write
(fn write! [p content]
  "Atomically replace `p` with `content`: create the parent directory, write a
   sibling `.tmp` file, then rename it into place. On rename failure the temp
   file is removed and the error is re-raised."
  (let [dir (path.dirname p)
        tmp (.. p ".tmp")]
    (os.execute (.. "mkdir -p " (path.shell-quote dir) " 2>/dev/null"))
    (let [f (io.open tmp :w)]
      (when (not f)
        (error (.. "storage: cannot open " tmp " for write")))
      (f:write content)
      (f:close))
    (let [(ok? err) (os.rename tmp p)]
      (when (not ok?)
        (os.remove tmp)
        (error (.. "storage: rename " tmp " -> " p
                   " failed: " (tostring err)))))))

{: read : write!}
