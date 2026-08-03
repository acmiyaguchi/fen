;; Cooperative, process-local mutexes for file mutations.
;;
;; Callers must hold at most one file lock at a time. The lock state is kept in
;; the non-reloadable sibling module so /reload cannot strand live waiters.
;; A holder coroutine must be resumed to unwind: if it were garbage-collected
;; while suspended, its lock would remain stranded. The agent always resumes
;; coroutines to unwind, so this cannot occur in practice.

(local path-util (require :fen.util.path))
(local state (require :fen.util.file_mutex_state))

(fn canonical-path [path]
  "Resolve absolute, relative, and symlinked spellings when GNU readlink is available.
   The physical-directory fallback is portable POSIX, but cannot resolve a final
   symlink on platforms without readlink -f."
  (let [pipe (io.popen (.. "readlink -f -- " (path-util.shell-quote path)
                            " 2>/dev/null") :r)
        resolved (and pipe (pipe:read :*l))]
    (when pipe (pipe:close))
    (if (and resolved (not= resolved "")) resolved (path-util.realpath path))))

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
    (if (not entry.owner)
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
