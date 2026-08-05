;; Filesystem and XDG path helpers shared across core modules.
;;
;; POSIX-only by default. Lua 5.4's stdlib has no stat/lstat, so filesystem and
;; environment probes are routed through an injectable backend
;; (fen.util.path.backend). The default backend
;; (fen.util.path.backends.posix) prefers LuaFileSystem and otherwise shells
;; out via POSIX tools, exactly as before; a host lacking a POSIX shell can
;; pre-populate `package.loaded["fen.util.path.backend"]` with its own backend
;; (getenv/stat/list-dir/pwd-physical). This mirrors the fen.util.http seam:
;; one mechanism (the injectable backend) with the current behavior as the
;; default. See docs/architecture.md.
;;
;; All shell-bound helpers route their input through `shell-quote`, so callers
;; can pass arbitrary user paths without escaping.
;;
;; Conventions match the duplicated copies these helpers replace:
;;   - `home` falls back to "/tmp" so a missing $HOME doesn't crash.
;;   - `config-dir`/`state-dir` take an app name and slot under the XDG roots.
;;   - `cwd` prefers $PWD (preserves the user's symlink spelling) and only
;;     falls back to physical pwd when PWD is unset.
;;
;; Path grammar stays "/"-separated in this module; a non-POSIX separator is
;; not a probe, so it belongs to a future backend surface rather than here.

;; Resolved once at load, mirroring fen.util.http. On /reload the module
;; re-requires the backend, and tests swap it by pre-loading
;; package.loaded before requiring this module (fen.testing.stub-path-vfs!).
(local backend (require :fen.util.path.backend))

(local M {})

;; @doc fen.util.path.home
;; kind: function
;; signature: (home) -> string
;; summary: Return HOME with a /tmp fallback so path helpers remain usable in stripped-down test or daemon environments.
;; tags: util paths xdg
(fn M.home []
  (or (backend.getenv :HOME) "/tmp"))

;; @doc fen.util.path.config-home
;; kind: function
;; signature: (config-home) -> string
;; summary: Return XDG_CONFIG_HOME or the conventional ~/.config directory under the resolved home path.
;; tags: util paths xdg
(fn M.config-home []
  (let [xdg (backend.getenv :XDG_CONFIG_HOME)]
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
  (let [xdg (backend.getenv :XDG_STATE_HOME)]
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
  (let [xdg (backend.getenv :XDG_DATA_HOME)]
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

;; @doc fen.util.path.ensure-dir!
;; kind: function
;; signature: (ensure-dir! dir) -> nil
;; summary: Create dir (and missing parents) with POSIX mkdir -p, swallowing failures so callers can attempt their write and surface a clearer error.
;; tags: util paths filesystem
(fn M.ensure-dir! [dir]
  ;; A write, not a probe: the #473 seam covers read probes and env lookups.
  ;; ensure-dir! stays a direct POSIX mkdir; a host that fully virtualizes
  ;; writes would extend the backend surface, which is out of scope here.
  (os.execute (.. "mkdir -p " (M.shell-quote dir))))

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
;; summary: Resolve a directory through the backend's physical pwd probe, returning its physical path or nil if the probe fails.
;; tags: util paths shell
(fn M.pwd-physical [dir]
  (backend.pwd-physical dir))

;; @doc fen.util.path.cwd
;; kind: function
;; signature: (cwd) -> string
;; summary: Return the user's current directory spelling from PWD, falling back to a physical pwd probe and then . .
;; tags: util paths cwd
(fn M.cwd []
  (or (backend.getenv :PWD) (M.pwd-physical ".") "."))

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

;; @doc fen.util.path.file-exists?
;; kind: function
;; signature: (file-exists? path) -> boolean
;; summary: Return true only for regular files, delegating the stat probe to the injectable backend.
;; tags: util paths filesystem
(fn M.file-exists? [path]
  (= (backend.stat path) :file))

;; @doc fen.util.path.dir-exists?
;; kind: function
;; signature: (dir-exists? path) -> boolean
;; summary: Return true only for directories, delegating the stat probe to the injectable backend.
;; tags: util paths filesystem
(fn M.dir-exists? [path]
  (= (backend.stat path) :directory))

;; @doc fen.util.path.list-dir
;; kind: function
;; signature: (list-dir dir) -> [string]
;; summary: Return immediate child names of dir (excluding . and ..), or [] for
;;   an absent/unreadable directory, via the injectable backend.
;; tags: util paths filesystem
(fn M.list-dir [dir]
  (backend.list-dir dir))

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
