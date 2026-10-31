;; File commit for the write and edit tools (#654, #655, #656, #657).
;;
;; stage! writes the new content to a temp file beside the target, checking
;; every write and the close; commit! renames it over the target with one
;; rename(2), so a reader (or the disk after the process dies) sees the old or
;; the new content, never a prefix. Callers yield only while staging and never
;; between their commit point and their return, so a cancel (raised at a
;; yield) means nothing changed. A batch is cancel-atomic, not crash-atomic:
;; each rename is its own system call. Callers hold fen.util.file_mutex
;; with-files, which serializes fen's own writers across processes; changed?
;; is the best-effort re-check just before the rename for everyone else (an
;; outside write between the check and the rename is still lost).

(local path (require :fen.util.path))
(local random (require :fen.util.random))
(local lfs (let [(ok? mod) (pcall require :lfs)] (and ok? mod)))

(local WRITE-CHUNK-SIZE 16384)
(local WINDOWS? (= (string.sub package.config 1 1) "\\"))

(fn maybe-yield [?yield-fn]
  (when ?yield-fn (?yield-fn)))

(fn attr [p key]
  (when (and lfs lfs.attributes)
    (let [(ok? v) (pcall lfs.attributes p key)]
      (when ok? v))))

(fn temp-id []
  (let [(ok? hex) (pcall (fn []
                           (pick-values 1
                                        (: (random.bytes 6) :gsub "."
                                           (fn [c]
                                             (string.format "%02x"
                                                            (string.byte c)))))))]
    (if ok? hex (string.format "%x%04x" (os.time) (math.random 0 0xffff)))))

(fn temp-path [real]
  (.. (path.dirname real) "/." (path.basename real) ".fen-" (temp-id) ".tmp"))

;; @doc fen.extensions.builtin_tools.commit.check-target
;; kind: function
;; signature: (check-target real) -> true | nil, string
;; summary: Refuse a commit over an existing target that is not a regular file or is not writable, so the rename never replaces a device, directory, or read-only file.
;; tags: builtin tools write edit filesystem
(fn check-target [real]
  (let [mode (attr real :mode)]
    (if (not mode)
        true
        (not= mode :file)
        (values nil (.. real ": not a regular file"))
        (let [(f err) (io.open real :r+)]
          (if f (do
                  (f:close)
                  true) (values nil err))))))

(fn permission-octal [perm]
  (var out "")
  (for [i 1 9 3]
    (let [triple (string.sub perm i (+ i 2))]
      (set out (.. out (tostring (+ (if (= (string.sub triple 1 1) "r") 4 0)
                                    (if (= (string.sub triple 2 2) "w") 2 0)
                                    (if (string.find (string.sub triple 3 3)
                                                     "[xst]")
                                        1
                                        0)))))))
  out)

(fn copy-mode! [real tmp]
  "Give tmp the target's permission bits (rename replaces the inode)."
  (let [want (attr real :permissions)
        have (attr tmp :permissions)]
    (if (or WINDOWS? (not want) (not have) (= want have))
        true
        (let [r (os.execute (.. "chmod " (permission-octal want) " "
                                (path.shell-quote tmp)))]
          (if (or (= r true) (= r 0))
              true
              (values nil (.. real ": cannot preserve file mode")))))))

(fn write-chunks [f content ?yield-fn]
  (let [s (or content "")
        total (length s)]
    (var i 1)
    (var err nil)
    (while (and (not err) (<= i total))
      (let [j (math.min total (+ i WRITE-CHUNK-SIZE -1))
            (ok? werr) (f:write (string.sub s i j))]
        (if ok?
            (do
              (set i (+ j 1))
              (maybe-yield ?yield-fn))
            (set err (or werr "write failed")))))
    (if err (values nil err) true)))

;; @doc fen.extensions.builtin_tools.commit.stage!
;; kind: function
;; signature: (stage! real content yield-fn?) -> tmp-path | nil, string
;; summary: Write content to a temp file in real's directory, yielding between chunks and checking every write and the close; a failure or a raise at a yield removes the temp.
;; tags: builtin tools write edit filesystem cooperative
(fn stage! [real content ?yield-fn]
  (let [tmp (temp-path real)
        (f open-err) (io.open tmp :wb)]
    (if (not f)
        (values nil (.. "cannot create temp file beside " real ": "
                        (tostring open-err)))
        (let [(ok? written? werr) (pcall write-chunks f content ?yield-fn)]
          (if (not ok?)
              (do
                (f:close)
                (os.remove tmp)
                (error written? 0))
              (let [(closed? cerr) (f:close)
                    (moded? merr) (if (and written? closed?)
                                      (copy-mode! real tmp)
                                      true)]
                (if (and written? closed? moded?)
                    tmp
                    (do
                      (os.remove tmp)
                      (values nil
                              (.. real ": "
                                  (tostring (or werr cerr merr "write failed"))))))))))))

;; @doc fen.extensions.builtin_tools.commit.discard!
;; kind: function
;; signature: (discard! tmps) -> nil
;; summary: Remove staged temp files that will not be committed.
;; tags: builtin tools write edit filesystem
(fn discard! [tmps]
  (each [_ tmp (ipairs tmps)]
    (os.remove tmp)))

;; @doc fen.extensions.builtin_tools.commit.changed?
;; kind: function
;; signature: (changed? real snapshot) -> boolean
;; summary: Re-read real and report whether it differs from the snapshot the edit was computed from (best-effort detection of other writers).
;; tags: builtin tools edit filesystem
(fn changed? [real snapshot]
  (let [f (io.open real :rb)]
    (if (not f)
        true
        (let [now (f:read :*a)]
          (f:close)
          (not= now snapshot)))))

;; @doc fen.extensions.builtin_tools.commit.commit!
;; kind: function
;; signature: (commit! tmp real) -> true | nil, string
;; summary: Rename a staged temp over its target with one rename(2) (no yield); on failure remove the temp and return the error.
;; tags: builtin tools write edit filesystem
(fn commit! [tmp real]
  (let [(ok? err) (os.rename tmp real)]
    (if ok?
        true
        ;; Windows rename(3) refuses an existing target: replace it in two steps there.
        (and WINDOWS? (os.remove real) (os.rename tmp real))
        true
        (do
          (os.remove tmp)
          (values nil (.. real ": rename failed: " (tostring err)))))))

{: check-target : stage! : discard! : changed? : commit!}
