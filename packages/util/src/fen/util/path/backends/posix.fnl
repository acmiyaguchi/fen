;; POSIX backend: Lua 5.4 has no stat/lstat, so prefer lfs, else shell out; all commands go through shell-quote.

(local M {})

;; Local shell-quote copy avoids a load-time cycle with the public module.
(fn shell-quote [s]
  (.. "'" (string.gsub (tostring s) "'" "'\\''") "'"))

;; lfs probe memo: :unknown = not probed; false = unavailable, stop retrying.
(var lfs-mod :unknown)

(fn lfs []
  (when (= lfs-mod :unknown)
    (let [(ok? mod) (pcall require :lfs)]
      (set lfs-mod (if ok? mod false))))
  (if lfs-mod lfs-mod nil))

(fn shell-stat [p]
  "Single-shell probe returning a mode string ('file'/'directory'/'other') or
   nil when the path is absent. Matches the lfs `mode` attribute for the cases
   the public helpers care about: a regular file (test -f, follows symlinks)
   and a directory (test -d, follows symlinks)."
  (let [pipe (io.popen (.. "p=" (shell-quote p)
                           "; if test -d \"$p\"; then echo directory;"
                           " elif test -f \"$p\"; then echo file;"
                           " elif test -e \"$p\"; then echo other; fi")
                       :r)]
    (if (not pipe) nil
        (let [out (pipe:read :*l)]
          (pipe:close)
          (if (and out (not= out "")) out nil)))))

;; @doc fen.util.path.backends.posix.getenv
;; kind: function
;; signature: (getenv name) -> string|nil
;; summary: Look up an environment variable through os.getenv for the default POSIX backend.
;; tags: util paths vfs env
(fn M.getenv [name]
  (os.getenv name))

(fn M.stat [path]
  "Return the path's mode string or nil. Prefer lfs to avoid spawning
   `/bin/sh` for every probe during extension discovery; fall back to a single
   POSIX `test` command when lfs is unavailable."
  (let [l (lfs)]
    (if (and l l.attributes)
        (let [(ok? mode) (pcall l.attributes path :mode)]
          (if ok? mode (shell-stat path)))
        (shell-stat path))))

(fn M.list-dir [dir ?yield-fn]
  "Return dir's immediate child names, or [] for an absent/unreadable
   directory. Prefer lfs to avoid spawning a shell per directory; fall back to
   a POSIX `ls -1A` probe. Yield between entries while draining either backend;
   errors raised by ?yield-fn (e.g. cancellation) propagate to the caller."
  (let [out []
        add! (fn [name]
               (when (and (not= name ".") (not= name "..") (not= name ""))
                 (table.insert out name)
                 (when ?yield-fn (?yield-fn))))]
    (when (= (M.stat dir) :directory)
      (let [l (lfs)]
        (if (and l l.dir)
            ;; lfs.dir raises when the directory cannot be opened; treat that as empty.
            (let [(ok? iter dir-obj) (pcall l.dir dir)]
              (when ok?
                (each [name (values iter dir-obj)]
                  (add! name))))
            (let [pipe (io.popen (.. "ls -1A " (shell-quote dir) " 2>/dev/null")
                                 :r)]
              (when pipe
                (each [line (pipe:lines)]
                  (add! line))
                (pipe:close))))))
    out))

;; @doc fen.util.path.backends.posix.pwd-physical
;; kind: function
;; signature: (pwd-physical dir) -> string|nil
;; summary: Resolve a directory through `pwd -P`, returning its physical path or nil if the shell probe fails.
;; tags: util paths vfs shell
(fn M.pwd-physical [dir]
  (let [pipe (io.popen (.. "cd " (shell-quote dir) " 2>/dev/null && pwd -P") :r)]
    (when pipe
      (let [out (pipe:read :*l)]
        (pipe:close)
        out))))

M
