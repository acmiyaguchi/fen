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

;; @doc fen.util.path.home
;; kind: function
;; signature: (home) -> string
;; summary: Return HOME with a /tmp fallback so path helpers remain usable in stripped-down test or daemon environments.
;; tags: util paths xdg
(fn M.home []
  (or (os.getenv :HOME) "/tmp"))

;; @doc fen.util.path.config-home
;; kind: function
;; signature: (config-home) -> string
;; summary: Return XDG_CONFIG_HOME or the conventional ~/.config directory under the resolved home path.
;; tags: util paths xdg
(fn M.config-home []
  (let [xdg (os.getenv :XDG_CONFIG_HOME)]
    (if (and xdg (not= xdg ""))
        xdg
        (.. (M.home) "/.config"))))

;; @doc fen.util.path.config-dir
;; kind: function
;; signature: (config-dir app) -> string
;; summary: Return the per-application configuration directory under the XDG config home.
;; tags: util paths xdg
(fn M.config-dir [app]
  (.. (M.config-home) "/" app))

;; @doc fen.util.path.state-home
;; kind: function
;; signature: (state-home) -> string
;; summary: Return XDG_STATE_HOME or the conventional ~/.local/state directory under the resolved home path.
;; tags: util paths xdg
(fn M.state-home []
  (let [xdg (os.getenv :XDG_STATE_HOME)]
    (if (and xdg (not= xdg ""))
        xdg
        (.. (M.home) "/.local/state"))))

;; @doc fen.util.path.state-dir
;; kind: function
;; signature: (state-dir app) -> string
;; summary: Return the per-application state directory under the XDG state home.
;; tags: util paths xdg
(fn M.state-dir [app]
  (.. (M.state-home) "/" app))

;; @doc fen.util.path.data-home
;; kind: function
;; signature: (data-home) -> string
;; summary: Return XDG_DATA_HOME or the conventional ~/.local/share directory under the resolved home path.
;; tags: util paths xdg
(fn M.data-home []
  (let [xdg (os.getenv :XDG_DATA_HOME)]
    (if (and xdg (not= xdg ""))
        xdg
        (.. (M.home) "/.local/share"))))

;; @doc fen.util.path.data-dir
;; kind: function
;; signature: (data-dir app) -> string
;; summary: Return the per-application data directory under the XDG data home.
;; tags: util paths xdg
(fn M.data-dir [app]
  (.. (M.data-home) "/" app))

;; @doc fen.util.path.shell-quote
;; kind: function
;; signature: (shell-quote s) -> string
;; summary: Quote a value as one POSIX shell word for helper functions that must invoke system tools safely.
;; tags: util paths shell
(fn M.shell-quote [s]
  (.. "'" (string.gsub (tostring s) "'" "'\\''") "'"))

;; @doc fen.util.path.dirname
;; kind: function
;; signature: (dirname path) -> string
;; summary: Return the directory portion of a path, using . for bare names and / for root-level paths.
;; tags: util paths
(fn M.dirname [path]
  (let [d (string.match path "^(.*)/[^/]+$")]
    (if (not d) "."
        (= d "") "/"
        d)))

;; @doc fen.util.path.basename
;; kind: function
;; signature: (basename path) -> string
;; summary: Return the final path component while tolerating a trailing slash.
;; tags: util paths
(fn M.basename [path]
  (or (string.match path "([^/]+)/?$") path))

;; @doc fen.util.path.pwd-physical
;; kind: function
;; signature: (pwd-physical dir) -> string|nil
;; summary: Resolve a directory through `pwd -P`, returning its physical path or nil if the shell probe fails.
;; tags: util paths shell
(fn M.pwd-physical [dir]
  (let [pipe (io.popen (.. "cd " (M.shell-quote dir)
                            " 2>/dev/null && pwd -P") :r)]
    (when pipe
      (let [out (pipe:read :*l)]
        (pipe:close)
        out))))

;; @doc fen.util.path.cwd
;; kind: function
;; signature: (cwd) -> string
;; summary: Return the user's current directory spelling from PWD, falling back to a physical pwd probe and then . .
;; tags: util paths cwd
(fn M.cwd []
  (or (os.getenv :PWD) (M.pwd-physical ".") "."))

;; @doc fen.util.path.realpath
;; kind: function
;; signature: (realpath path) -> string
;; summary: Resolve the directory portion of a path physically while preserving the original basename.
;; tags: util paths
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

;; @doc fen.util.path.file-exists?
;; kind: function
;; signature: (file-exists? path) -> boolean
;; summary: Return true only for regular files, preferring LuaFileSystem and falling back to POSIX test -f.
;; tags: util paths filesystem
(fn M.file-exists? [path]
  "True only for regular files. Prefer lfs to avoid spawning `/bin/sh` for
   every probe during extension discovery; fall back to POSIX `test -f` when
   lfs is unavailable."
  (let [(used-lfs? mode) (stat-mode path)]
    (if used-lfs? (= mode :file) (test-flag? path "-f"))))

;; @doc fen.util.path.dir-exists?
;; kind: function
;; signature: (dir-exists? path) -> boolean
;; summary: Return true only for directories, preferring LuaFileSystem and falling back to POSIX test -d.
;; tags: util paths filesystem
(fn M.dir-exists? [path]
  (let [(used-lfs? mode) (stat-mode path)]
    (if used-lfs? (= mode :directory) (test-flag? path "-d"))))

;; @doc fen.util.path.ancestors-root-to-leaf
;; kind: function
;; signature: (ancestors-root-to-leaf start) -> [string]
;; summary: Return a physical ancestor chain from / to start for deterministic project-context discovery.
;; tags: util paths discovery
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
