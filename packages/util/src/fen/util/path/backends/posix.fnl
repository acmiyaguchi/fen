;; Default (POSIX) filesystem/env backend for fen.util.path.
;;
;; Lua 5.4's stdlib has no stat/lstat, so filesystem probes prefer
;; LuaFileSystem when available and otherwise shell out via POSIX tools
;; (`test`, `ls -1A`, `pwd -P`). All shell-bound commands route their input
;; through `shell-quote`, so callers can pass arbitrary user paths safely.
;;
;; This is the seam's default backend (see fen.util.path.backend). The public
;; module derives home/XDG/cwd/realpath/... from these primitives, so keeping
;; the POSIX behavior here means the injectable seam changes nothing about
;; default CLI behavior. A host that lacks a POSIX shell supplies its own
;; backend with the same surface: getenv/stat/list-dir/pwd-physical.

(local M {})

;; Local quoting helper for this backend's shell commands. fen.util.path
;; exposes the public `shell-quote`; the backend keeps its own copy so it does
;; not require the public module (which requires this backend), avoiding a
;; load-time cycle.
(fn shell-quote [s]
  (.. "'" (string.gsub (tostring s) "'" "'\\''") "'"))

;; Lazily resolve LuaFileSystem once. `:unknown` means "not yet probed";
;; `false` means "probed and unavailable" so we stop retrying the require.
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

;; @doc fen.util.path.backends.posix.stat
;; kind: function
;; signature: (stat path) -> string|nil
;; summary: Return a path's mode ('file'/'directory'/...) preferring LuaFileSystem and falling back to a single POSIX test probe, or nil if absent.
;; tags: util paths vfs filesystem
(fn M.stat [path]
  "Return the path's mode string or nil. Prefer lfs to avoid spawning
   `/bin/sh` for every probe during extension discovery; fall back to a single
   POSIX `test` command when lfs is unavailable."
  (let [l (lfs)]
    (if (and l l.attributes)
        (let [(ok? mode) (pcall l.attributes path :mode)]
          (if ok? mode nil))
        (shell-stat path))))

;; @doc fen.util.path.backends.posix.list-dir
;; kind: function
;; signature: (list-dir dir) -> [string]
;; summary: Return immediate child names of dir (excluding . and ..), preferring LuaFileSystem and falling back to POSIX ls -1A.
;; tags: util paths vfs filesystem
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
