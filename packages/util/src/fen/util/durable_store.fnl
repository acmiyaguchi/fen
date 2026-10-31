;; One writer per durable resource: a kernel-released lock plus a private atomic write.
;; The lock pairs the process-local FIFO mutex (coroutines in one process) with an
;; advisory lfs.lock on a stable `.lock` inode (across processes); the kernel drops
;; it when the holder dies, so there is no stale-lock reclaim. Writes create the
;; temp file private before any byte lands, then rename it over the target.

(local mutex (require :fen.util.file_mutex))
(local path (require :fen.util.path))
(local clock (require :fen.util.clock))
(local lfs (let [(ok? mod) (pcall require :lfs)] (and ok? mod)))

(local DEFAULT-LOCK-TIMEOUT-MS 1000)

(fn windows? []
  (= (string.sub package.config 1 1) "\\"))

;; @doc fen.util.durable_store.ensure-private-dir!
;; kind: function
;; signature: (ensure-private-dir! dir) -> boolean
;; summary: Create dir and missing parents readable only by the owner (umask 077); existing directories keep their mode.
;; tags: util filesystem durable secrets
(fn ensure-private-dir! [dir]
  (if (windows?)
      (path.ensure-dir! dir)
      (os.execute (.. "umask 077 && mkdir -p " (path.shell-quote dir)
                      " 2>/dev/null"))))

(fn acquire-kernel-lock! [f ?yield timeout-ms]
  (let [deadline (+ (clock.monotonic-ms) timeout-ms)]
    (var locked? (lfs.lock f :w))
    (while (and (not locked?) (< (clock.monotonic-ms) deadline))
      (if ?yield (?yield) (clock.sleep-ms 10))
      (set locked? (lfs.lock f :w)))
    locked?))

(fn with-lock [lock-path ?yield body ?opts]
  "Serialize BODY across coroutines and processes on LOCK-PATH, a file that
   is never renamed or deleted (fcntl locks attach to the inode). Contention
   yields through ?YIELD (or sleeps when synchronous) for at most
   `(?. ?opts :timeout-ms)` (default 1 s), then errors. Closing the lock file
   releases the kernel lock on success, error, or cancellation; the kernel
   also releases it if the process dies."
  (let [timeout-ms (or (?. ?opts :timeout-ms) DEFAULT-LOCK-TIMEOUT-MS)]
    (path.ensure-dir! (path.dirname lock-path))
    ;; Catch inside the mutex and re-raise outside it, so error values pass
    ;; through unchanged (no file:line prefix added by the mutex re-raise).
    (let [[ok result] (mutex.with-file lock-path
                        ?yield
                        (fn []
                          (if (not (and lfs lfs.lock))
                              ;; Without lfs only coroutines in this process are serialized.
                              [(pcall body)]
                              (let [f (io.open lock-path :a)]
                                (if (not f)
                                    [false
                                     (.. "durable_store: cannot open lock "
                                         lock-path)]
                                    (let [outcome [(pcall #(if (acquire-kernel-lock! f
                                                                                     ?yield
                                                                                     timeout-ms)
                                                               (body)
                                                               (error (.. "durable_store: lock busy: "
                                                                          lock-path)
                                                                      0)))]]
                                      (f:close)
                                      outcome))))))]
      (if ok result (error result 0)))))

(fn create-private! [tmp]
  "Create TMP exclusively with owner-only permissions before anything is
   written to it. Returns an open binary write handle, or nil."
  (if (windows?)
      ;; NTFS permissions come from the (per-user) parent directory ACL.
      (io.open tmp :wb)
      (when (os.execute (.. "umask 077 && set -C && : > "
                            (path.shell-quote tmp) " 2>/dev/null"))
        (io.open tmp :wb))))

(fn replace! [tmp target]
  (let [(ok? err) (os.rename tmp target)]
    (if (or ok? (not (windows?)))
        (values ok? err)
        ;; Windows rename does not replace an existing target.
        (do
          (os.remove target)
          (os.rename tmp target)))))

(fn write-private! [target content]
  "Write CONTENT to a sibling of TARGET created owner-only (0600) before any
   byte is written, then rename it over TARGET so readers never observe a
   partial file. Any failure removes the temp file and errors; no token-bearing
   residue is left behind except across a kill between create and rename."
  (let [seed (os.tmpname)]
    (os.remove seed)
    (let [tmp (.. target "." (path.basename seed))
          f (create-private! tmp)]
      (when (not f)
        (os.remove tmp)
        (error (.. "durable_store: cannot create " tmp) 0))
      (let [(ok? err) (pcall #(do
                                (assert (f:write content))
                                (assert (f:close))))]
        (when (not ok?)
          (pcall #(f:close))
          (os.remove tmp)
          (error (.. "durable_store: write to " tmp " failed: " (tostring err))
                 0)))
      (let [(ok? err) (replace! tmp target)]
        (when (not ok?)
          (os.remove tmp)
          (error (.. "durable_store: rename " tmp " -> " target " failed: "
                     (tostring err)) 0)))
      true)))

{: with-lock : write-private! : ensure-private-dir!}
