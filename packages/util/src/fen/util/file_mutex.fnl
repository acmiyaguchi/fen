;; Cooperative process-local file mutexes: FIFO waiters, one lock per coroutine, re-acquire rejected.
;; Lock/cache state lives in the non-reloadable sibling so /reload cannot strand waiters; holders must be resumed to unwind.
;; with-files adds a kernel lock (lfs.lock: fcntl on POSIX, _locking on Windows) on a per-path lock file under the
;; state dir, so fen writers in different processes (sibling subagents) are serialized too (#657). The kernel drops
;; it when the process dies, so there is no stale-lock reclaim. It orders fen's own writers only.

(local path-util (require :fen.util.path))
(local io-util (require :io))
(local clock (require :fen.util.clock))
(local sha256 (require :fen.util.sha256))
(local state (require :fen.util.file_mutex_state))
(local CANONICAL-CACHE-LIMIT 256)
(local KERNEL-LOCK-WAIT-MS 30000)
(local KERNEL-LOCK-POLL-MS 10)
(local lfs (let [(ok? mod) (pcall require :lfs)] (and ok? mod)))

(fn current-directory []
  (if (and lfs lfs.currentdir)
      (let [(ok? cwd) (pcall lfs.currentdir)]
        (if (and ok? cwd) cwd (path-util.cwd)))
      (path-util.cwd)))

(fn absolute-spelling [path cwd]
  (if (= (string.sub path 1 1) "/")
      path
      (.. cwd "/" path)))

(fn has-parent-component? [path]
  (var found? false)
  (each [part (string.gmatch path "[^/]+")]
    (when (= part "..") (set found? true)))
  found?)

(fn normalize-absolute [path]
  (let [parts []]
    (each [part (string.gmatch path "[^/]+")]
      (if (= part "..")
          (when (> (length parts) 0) (table.remove parts))
          (when (not= part ".") (table.insert parts part))))
    (if (= (length parts) 0)
        "/"
        (.. "/" (table.concat parts "/")))))

(fn has-symlink-component? [path]
  ;; Without lfs lstat capability the pure spelling is ambiguous; fall back to readlink -f.
  (if (not (and lfs lfs.symlinkattributes))
      true
      (do
        (var current "")
        (var found? false)
        (each [part (string.gmatch path "[^/]+")]
          (when (not found?)
            (set current (if (= current "")
                             (.. "/" part)
                             (.. current "/" part)))
            (let [(ok? attrs) (pcall lfs.symlinkattributes current)]
              (when (and ok? attrs (= attrs.mode :link))
                (set found? true)))))
        found?)))

(fn pure-canonical-path [path cwd]
  (let [absolute (absolute-spelling path cwd)]
    ;; Lexical `..` normalization is unsafe across symlinks; leave those to the physical resolver.
    (if (has-parent-component? absolute)
        (values (normalize-absolute absolute) true)
        (let [normalized (normalize-absolute absolute)]
          (values normalized (has-symlink-component? normalized))))))

(fn shell-canonical-path [path fallback]
  (let [pipe (io-util.popen (.. "readlink -f -- " (path-util.shell-quote path)
                                " 2>/dev/null") :r)
        resolved (and pipe (pipe:read :*l))]
    (when pipe (pipe:close))
    (if (and resolved (not= resolved "")) resolved (path-util.realpath path))))

(fn canonical-path [path]
  "Resolve a path without forking for ordinary spellings; use readlink only
   when a symlink (or an unavailable pure-Lua link probe) makes the spelling
   ambiguous. Results are memoized in the non-reloadable state module."
  (let [cwd (current-directory)
        previous-cwd (. state :canonical-cache-cwd)]
    ;; Relative spellings are only reusable while the process cwd is stable.
    (when (and previous-cwd (not= previous-cwd cwd))
      (tset state :canonical-cache {})
      (tset state :canonical-cache-size 0))
    (tset state :canonical-cache-cwd cwd)
    (let [cached (. (. state :canonical-cache) path)]
      (if cached
          cached
          ;; A symlink retargeted mid-session can leave this memo stale (accepted).
          (let [(pure ambiguous?) (pure-canonical-path path cwd)
                resolved (if ambiguous?
                             (shell-canonical-path path pure)
                             pure)]
            (when (>= (. state :canonical-cache-size) CANONICAL-CACHE-LIMIT)
              (tset state :canonical-cache {})
              (tset state :canonical-cache-size 0))
            (tset (. state :canonical-cache) path resolved)
            (tset state :canonical-cache-size
                  (+ (. state :canonical-cache-size) 1))
            resolved)))))

(fn current-owner []
  (let [(co main?) (coroutine.running)]
    (if (or (not co) main?) nil co)))

(fn clear-if-idle! [key entry]
  (when (and (= (length entry.waiters) 0) (not entry.owner))
    (tset state.locks key nil)))

(fn remove-waiter! [entry owner]
  (var i 1)
  (while (<= i (length entry.waiters))
    (if (= (. entry.waiters i) owner)
        (table.remove entry.waiters i)
        (set i (+ i 1)))))

(fn release! [key owner]
  (let [entry (. state.locks key)]
    (assert (and entry (= entry.owner owner)) "file mutex release by non-owner")
    (set entry.owner nil)
    (clear-if-idle! key entry)))

(fn acquire! [key yield!]
  (let [owner (current-owner)
        entry (or (. state.locks key) {:owner nil :waiters []})]
    (when (not (. state.locks key)) (tset state.locks key entry))
    (assert (not (and owner (= entry.owner owner)))
            (.. "re-entrant file mutex acquire: " key))
    (if (and (not entry.owner) (= (length entry.waiters) 0))
        (do
          (set entry.owner owner)
          owner)
        (do
          (assert yield! (.. "file mutex contention in synchronous mutation: "
                             key))
          (assert owner
                  "file mutex cooperative mutation must run in a coroutine")
          (table.insert entry.waiters owner)
          (while (or entry.owner (not= (. entry.waiters 1) owner))
            (let [(ok? err) (pcall yield!)]
              (when (not ok?)
                (remove-waiter! entry owner)
                (clear-if-idle! key entry)
                (error err))))
          (table.remove entry.waiters 1)
          (set entry.owner owner)
          owner))))

;; @doc fen.util.file_mutex.with-file
;; kind: function
;; signature: (with-file path yield! fn-body) -> any
;; summary: Run fn-body while holding the FIFO mutex for path's canonical filesystem spelling, releasing it even when fn-body throws.
;; tags: util filesystem mutex cooperative reload
(fn with-file [path yield! fn-body]
  (let [key (canonical-path path)
        owner (acquire! key yield!)
        (ok? result) (pcall fn-body)]
    (release! key owner)
    (if ok? result (error result))))

(fn lock-dir []
  (.. (path-util.state-dir :fen) "/locks"))

(fn ensure-lock-dir! [dir]
  (when (not (and lfs lfs.attributes (= (lfs.attributes dir :mode) :directory)))
    (path-util.ensure-dir! dir))
  (and lfs lfs.attributes (= (lfs.attributes dir :mode) :directory)))

;; @doc fen.util.file_mutex.kernel-lock-path
;; kind: function
;; signature: (kernel-lock-path path) -> string
;; summary: Return the per-path lock file that with-files locks for path's canonical spelling (for diagnostics and tests).
;; tags: util filesystem mutex
(fn kernel-lock-path [p]
  (.. (lock-dir) "/" (sha256.hex-digest (canonical-path p)) ".lock"))

(fn acquire-kernel-lock! [key yield!]
  "Open key's lock file and take an exclusive kernel lock on it, yielding
   (or sleeping) while another process holds it. Returns the open handle,
   or nil when no kernel lock is available here (no lfs.lock, or the lock
   dir cannot be created); then only the in-process mutex applies."
  (when (and lfs lfs.lock)
    (let [dir (lock-dir)
          f (and (ensure-lock-dir! dir)
                 (io-util.open (.. dir "/" (sha256.hex-digest key) ".lock") :a))]
      (when f
        (let [(ok? err) (pcall (fn []
                                 (let [deadline (+ (clock.monotonic-ms)
                                                   KERNEL-LOCK-WAIT-MS)]
                                   (var locked? (lfs.lock f :w))
                                   (while (not locked?)
                                     (when (>= (clock.monotonic-ms) deadline)
                                       (error (.. key
                                                  ": locked by another fen process; try again")
                                              0))
                                     (if yield! (yield!)
                                         (clock.sleep-ms KERNEL-LOCK-POLL-MS))
                                     (set locked? (lfs.lock f :w))))))]
          (if ok?
              f
              (do
                ;; Closing the handle releases the lock (and any partial claim).
                (f:close)
                (error err 0))))))))

;; @doc fen.util.file_mutex.with-files
;; kind: function
;; signature: (with-files paths yield! fn-body) -> any
;; summary: Run fn-body holding, for every path, the in-process FIFO mutex and a cross-process kernel lock, taken in sorted canonical order and released even when fn-body throws.
;; tags: util filesystem mutex cooperative reload
(fn with-files [paths yield! fn-body]
  (let [keys []
        seen {}]
    (each [_ p (ipairs paths)]
      (let [key (canonical-path p)]
        (when (not (. seen key))
          (tset seen key true)
          (table.insert keys key))))
    ;; One global order, so two batches over the same files cannot deadlock.
    (table.sort keys)
    (let [held []
          handles []
          release-all! (fn []
                         (for [i (length handles) 1 -1]
                           (: (. handles i) :close))
                         (for [i (length held) 1 -1]
                           (let [h (. held i)]
                             (release! h.key h.owner))))
          (ok? result) (pcall (fn []
                                (each [_ key (ipairs keys)]
                                  (table.insert held
                                                {: key
                                                 :owner (acquire! key yield!)}))
                                (each [_ key (ipairs keys)]
                                  (let [h (acquire-kernel-lock! key yield!)]
                                    (when h (table.insert handles h))))
                                (fn-body)))]
      (release-all!)
      (if ok? result (error result 0)))))

{:with-file with-file
 :with-files with-files
 :canonical-path canonical-path
 :kernel-lock-path kernel-lock-path}
