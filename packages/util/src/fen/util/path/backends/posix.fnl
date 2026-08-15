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
                           " elif test -e \"$p\"; then echo other; fi") :r)]
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
          (if ok? mode nil))
        (shell-stat path))))

(fn M.list-dir [dir]
  "Return dir's immediate child names, or [] for an absent/unreadable
   directory. Prefer lfs to avoid spawning a shell per directory; fall back to
   a POSIX `ls -1A` probe."
  (let [out []]
    (when (= (M.stat dir) :directory)
      (let [l (lfs)]
        (if (and l l.dir)
            (pcall (fn []
                     (each [name (l.dir dir)]
                       (when (and (not= name ".") (not= name "..")
                                  (not= name ""))
                         (table.insert out name)))))
            (let [pipe (io.popen (.. "ls -1A " (shell-quote dir)
                                      " 2>/dev/null") :r)]
              (when pipe
                (let [data (pipe:read :*a)]
                  (pipe:close)
                  (each [line (string.gmatch (or data "") "([^\n]+)")]
                    (when (not= line "")
                      (table.insert out line)))))))))
    out))

;; @doc fen.util.path.backends.posix.pwd-physical
;; kind: function
;; signature: (pwd-physical dir) -> string|nil
;; summary: Resolve a directory through `pwd -P`, returning its physical path or nil if the shell probe fails.
;; tags: util paths vfs shell
(fn M.pwd-physical [dir]
  (let [pipe (io.popen (.. "cd " (shell-quote dir)
                            " 2>/dev/null && pwd -P") :r)]
    (when pipe
      (let [out (pipe:read :*l)]
        (pipe:close)
        out))))

M
