;; Filesystem and XDG path helpers shared across core modules.
;;
;; POSIX-only. Lua 5.4's stdlib has no stat/lstat, so filesystem probes use
;; LuaFileSystem when available and otherwise shell out via POSIX `test`.
;; All shell-bound functions route their input through `shell-quote`, so callers
;; can pass arbitrary user paths without escaping.
;;
;; Conventions match the duplicated copies these helpers replace:
;;   - `home` falls back to "/tmp" so a missing $HOME doesn't crash.
;;   - `config-dir`/`state-dir` take an app name and slot under the XDG roots.
;;   - `cwd` prefers $PWD (preserves the user's symlink spelling) and only
;;     falls back to physical pwd when PWD is unset.

(local M {})

(fn M.home []
  (or (os.getenv :HOME) "/tmp"))

(fn M.config-home []
  (let [xdg (os.getenv :XDG_CONFIG_HOME)]
    (if (and xdg (not= xdg ""))
        xdg
        (.. (M.home) "/.config"))))

(fn M.config-dir [app]
  (.. (M.config-home) "/" app))

(fn M.state-home []
  (let [xdg (os.getenv :XDG_STATE_HOME)]
    (if (and xdg (not= xdg ""))
        xdg
        (.. (M.home) "/.local/state"))))

(fn M.state-dir [app]
  (.. (M.state-home) "/" app))

(fn M.data-home []
  (let [xdg (os.getenv :XDG_DATA_HOME)]
    (if (and xdg (not= xdg ""))
        xdg
        (.. (M.home) "/.local/share"))))

(fn M.data-dir [app]
  (.. (M.data-home) "/" app))

(fn M.shell-quote [s]
  (.. "'" (string.gsub (tostring s) "'" "'\\''") "'"))

(fn M.dirname [path]
  (let [d (string.match path "^(.*)/[^/]+$")]
    (if (not d) "."
        (= d "") "/"
        d)))

(fn M.basename [path]
  (or (string.match path "([^/]+)/?$") path))

(fn M.pwd-physical [dir]
  (let [pipe (io.popen (.. "cd " (M.shell-quote dir)
                            " 2>/dev/null && pwd -P") :r)]
    (when pipe
      (let [out (pipe:read :*l)]
        (pipe:close)
        out))))

(fn M.cwd []
  (or (os.getenv :PWD) (M.pwd-physical ".") "."))

(fn M.realpath [path]
  (let [dir (M.dirname path)
        base (M.basename path)
        real-dir (M.pwd-physical dir)]
    (if real-dir (.. real-dir "/" base) path)))

(var lfs-mod :unknown)

(fn lfs []
  (when (= lfs-mod :unknown)
    (let [(ok? mod) (pcall require :lfs)]
      (set lfs-mod (if ok? mod false))))
  (if lfs-mod lfs-mod nil))

(fn stat-mode [p]
  "Return (values true mode) when lfs handled the stat, even if mode is nil
   for a missing path. Return (values false nil) only when lfs is unavailable
   or errored before producing a usable stat result."
  (let [l (lfs)]
    (if (and l l.attributes)
        (let [(ok? mode) (pcall l.attributes p :mode)]
          (if ok? (values true mode) (values false nil)))
        (values false nil))))

(fn test-flag? [path flag]
  (let [pipe (io.popen (.. "test " flag " " (M.shell-quote path)
                            " && echo y") :r)]
    (if (not pipe) false
        (let [out (pipe:read :*l)]
          (pipe:close)
          (= out "y")))))

(fn M.file-exists? [path]
  "True only for regular files. Prefer lfs to avoid spawning `/bin/sh` for
   every probe during extension discovery; fall back to POSIX `test -f` when
   lfs is unavailable."
  (let [(used-lfs? mode) (stat-mode path)]
    (if used-lfs? (= mode :file) (test-flag? path "-f"))))

(fn M.dir-exists? [path]
  (let [(used-lfs? mode) (stat-mode path)]
    (if used-lfs? (= mode :directory) (test-flag? path "-d"))))

(fn M.ancestors-root-to-leaf [start]
  "Return start's ancestor chain root-to-leaf, using its physical path so the
   chain is canonical. Always includes \"/\" as the first element."
  (let [physical (or (M.pwd-physical start) start)
        parts []]
    (var cur physical)
    (var done? false)
    (while (not done?)
      (table.insert parts 1 cur)
      (if (= cur "/")
          (set done? true)
          (set cur (M.dirname cur))))
    parts))

M
