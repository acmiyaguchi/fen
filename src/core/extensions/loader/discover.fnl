;; Filesystem walk for external extensions.
;;
;; Combines the search roots from `$FEN_EXTENSIONS_PATH` and the XDG config
;; locations with explicit `--extension <path>` entries, then resolves each
;; candidate to a spec (name, entry path, manifest table, dir). The loader
;; consumes the spec list and decides what to actually load.

(local path (require :util.path))
(local log (require :util.log))
(local manifest-mod (require :core.extensions.loader.manifest))

(local M {})

(fn hidden-or-disabled? [name]
  (let [c (string.sub name 1 1)]
    (or (= c ".") (= c "_"))))

(fn command-output-lines [cmd]
  (let [p (io.popen cmd)
        out []]
    (when p
      (each [line (p:lines)]
        (table.insert out line))
      (p:close))
    out))

(fn direct-children [dir]
  (if (not (path.dir-exists? dir))
      []
      (command-output-lines
        (.. "find " (path.shell-quote dir)
            " -mindepth 1 -maxdepth 1 -print"))))

(fn split-path-list [s]
  (let [out []]
    (when (and s (not= s ""))
      (each [part (string.gmatch s "[^:]+")]
        (when (not= part "")
          (table.insert out part))))
    out))

(fn candidate-roots []
  (let [roots []]
    (each [_ p (ipairs (split-path-list (os.getenv :FEN_EXTENSIONS_PATH)))]
      (table.insert roots p))
    (table.insert roots (.. (path.config-home) "/fen/extensions"))
    ;; Compatibility with the project name used elsewhere in this repo.
    (table.insert roots (.. (path.config-home) "/agent-fennel/extensions"))
    roots))

(fn spec-from-path [target explicit?]
  (let [is-dir? (path.dir-exists? target)
        entry (if is-dir? (manifest-mod.entry-path-for-dir target) target)
        manifest (if is-dir? (manifest-mod.read-manifest (manifest-mod.manifest-path target)) {})]
    (when (and entry
               (or (string.match entry "%.fnl$")
                   (string.match entry "%.lua$")))
      (let [name (or manifest.name
                     (if is-dir? (path.basename target)
                         (manifest-mod.strip-ext (path.basename target))))]
        {:name name
         :path target
         :entry entry
         :dir (if is-dir? target (path.dirname target))
         :manifest manifest
         :explicit? explicit?}))))

(fn M.discover-external [explicit-paths]
  "Walk the search roots and resolve explicit paths into specs. Explicit
   paths that don't yield a spec are warned about; root-discovered ones are
   silently dropped (the user didn't ask for them by name)."
  (let [out []]
    (each [_ root (ipairs (candidate-roots))]
      (each [_ child (ipairs (direct-children root))]
        (let [base (path.basename child)]
          (when (not (hidden-or-disabled? base))
            (let [spec (spec-from-path child false)]
              (when spec (table.insert out spec)))))))
    (each [_ p (ipairs (or explicit-paths []))]
      (let [spec (spec-from-path p true)]
        (if spec
            (table.insert out spec)
            (log.warn (.. "extension: no init.fnl/init.lua at " p)))))
    out))

M
