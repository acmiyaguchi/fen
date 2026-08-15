;; Default config-storage backend: XDG-file behavior with atomic
;; temp-file + rename writes.

(local path (require :fen.util.path))

(fn read [p]
  "Read entire file or return nil silently if missing. Config documents are
   optional and a missing file is the common case."
  (let [(f _) (io.open p :r)]
    (when f
      (let [s (f:read :*a)]
        (f:close)
        s))))

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
