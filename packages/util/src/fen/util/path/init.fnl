;; POSIX path/XDG helpers; filesystem/env probes route through the injectable fen.util.path.backend seam.
;; Path grammar stays "/"-separated here; other separators belong to a future backend surface.

;; Backend resolved once at load; /reload re-requires it; tests pre-load package.loaded first.
(local backend (require :fen.util.path.backend))

(local M {})

;; @doc fen.util.path.getenv
;; kind: function
;; signature: (getenv name) -> string|nil
;; summary: Read an environment variable through the injectable VFS backend so hosts without OS env vars can supply values (e.g. the reload dev-overlay gate) by swapping the backend.
;; tags: util paths vfs env
(fn M.getenv [name]
  (backend.getenv name))

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
  ;; ensure-dir! is a write, not a probe: stays direct POSIX mkdir outside the #473 seam.
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
