;; Cooperative, process-local mutexes for file mutations.
;;
;; Callers must hold at most one file lock at a time. Waiters are served in
;; FIFO order, and a coroutine that tries to acquire its current lock again is
;; rejected. The lock and canonical-path cache state are kept in the
;; non-reloadable sibling module so /reload cannot strand live waiters.
;; A holder coroutine must be resumed to unwind: if it were garbage-collected
;; while suspended, its lock would remain stranded. The agent always resumes
;; coroutines to unwind, so this cannot occur in practice.

(local path-util (require :fen.util.path))
(local io-util (require :io))
(local state (require :fen.util.file_mutex_state))
(local CANONICAL-CACHE-LIMIT 256)
(local lfs (let [(ok? mod) (pcall require :lfs)] (and ok? mod)))

;; Keep cache state compatible with an already-loaded non-reloadable state
;; module from before these fields were introduced.
(when (not (. state :canonical-cache))
  (tset state :canonical-cache {}))
(when (not (. state :canonical-cache-size))
  (tset state :canonical-cache-size 0))

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
  ;; lfs can identify a link without following it. If that capability is not
  ;; available, the pure spelling is ambiguous and must use readlink -f.
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
    ;; Lexical normalization across `..` is not safe in the presence of a
    ;; symlink, so leave those paths to the physical resolver.
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
          ;; A symlink retargeted mid-session can leave this memo stale;
          ;; that behavior is known and accepted.
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
        (do (set entry.owner owner) owner)
        (do
          (assert yield! (.. "file mutex contention in synchronous mutation: " key))
          (assert owner "file mutex cooperative mutation must run in a coroutine")
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

{:with-file with-file
 :canonical-path canonical-path}
