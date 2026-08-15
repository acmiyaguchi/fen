;; Default (POSIX) enumeration backend for extension discovery.
;; Policy: auto-discovery never treats plain `fen/extensions` as special (only dot-prefixed
;; `.fen/extensions`, XDG, and explicit env/CLI roots); first-party extensions come from the
;; embedded manifest registry, never package.path walking — a random cwd checkout must not
;; become an implicit trusted extension root.

(local path (require :fen.util.path))
(local log (require :fen.util.log))
(local manifest-mod (require :fen.core.extensions.loader.manifest))
(local process (require :fen.util.process))

(local M {})

(local embedded-first-party-manifests
  [:fen.extensions.agent_state.manifest
   :fen.extensions.builtin_tools.manifest
   :fen.extensions.default_prompt.manifest
   :fen.extensions.docs.manifest
   :fen.extensions.essentials.manifest
   :fen.extensions.extensions_inspector.manifest
   :fen.extensions.compact.manifest
   :fen.extensions.goal.manifest
   :fen.extensions.goal_headless.manifest
   :fen.extensions.handoff.manifest
   :fen.extensions.json.manifest
   :fen.extensions.mem.manifest
   :fen.extensions.plan.manifest
   :fen.extensions.todo.manifest
   :fen.extensions.print.manifest
   :fen.extensions.prompt.manifest
   :fen.extensions.profiler.manifest
   :fen.extensions.provider_anthropic.manifest
   :fen.extensions.provider_openai.manifest
   :fen.extensions.provider_sakana.manifest
   :fen.extensions.provider_shared.manifest
   :fen.extensions.queue.manifest
   :fen.extensions.session_jsonl.manifest
   :fen.extensions.sessions.manifest
   :fen.extensions.simplify.manifest
   :fen.extensions.skills.manifest
   :fen.extensions.status.manifest
   :fen.extensions.stdio.manifest
   :fen.extensions.steering.manifest
   :fen.extensions.subagent.manifest
   :fen.extensions.tui.manifest
   :fen.extensions.web.manifest])

(fn hidden-or-disabled? [name]
  (let [c (string.sub name 1 1)]
    (or (= c ".") (= c "_"))))

(fn split-lines [s]
  (let [out []]
    (each [line (string.gmatch (or s "") "([^\n]+)")]
      (table.insert out line))
    out))

(fn command-output-lines [cmd ?yield-fn]
  (let [p (io.popen cmd)]
    (if (not p)
        []
        (let [out (process.read-pipe-close p ?yield-fn)]
          (split-lines out)))))

(fn direct-children [dir ?yield-fn]
  (if (not (path.dir-exists? dir))
      []
      (command-output-lines
        (.. "find " (path.shell-quote dir)
            " -mindepth 1 -maxdepth 1 -print")
        ?yield-fn)))

(fn manifest-dirs [dir ?yield-fn]
  (if (not (path.dir-exists? dir))
      []
      (let [seen {}
            out []]
        (each [_ file (ipairs (command-output-lines
                                (.. "find " (path.shell-quote dir)
                                    " -type f \\( -name manifest.fnl -o -name manifest.lua \\) -print")
                                ?yield-fn))]
          (let [parent (path.dirname file)]
            (when (not (. seen parent))
              (tset seen parent true)
              (table.insert out parent))))
        out)))

(fn marker-root? [dir]
  (or (path.dir-exists? (.. dir "/.git"))
      (path.file-exists? (.. dir "/.git"))
      (path.dir-exists? (.. dir "/.hg"))
      (path.file-exists? (.. dir "/.hg"))))

(fn split-path-list [s]
  (let [out []]
    (when (and s (not= s ""))
      (each [part (string.gmatch s "[^:]+")]
        (when (not= part "")
          (table.insert out part))))
    out))

(fn M.first-party-roots []
  "Return trusted flat first-party overlay roots.

   First-party/bundled extensions are discovered by requiring the fixed
   embedded manifest module registry below. Development checkouts can override
   those bundled modules through the single-file launcher's `--extension-root`
   / `$FEN_EXTENSION_ROOT`; the launcher exposes those roots here as trusted
   flat first-party overlays and installs the flat-extension module searcher."
  (split-path-list (os.getenv :FEN_FIRST_PARTY_EXTENSIONS_PATH)))

(fn M.project-roots []
  "Project-local roots: .fen/extensions in cwd and ancestors, walking upward
   until a .git/.hg marker or filesystem root. Returned nearest-to-farthest so
   cwd-local extensions override ancestor-local extensions with the same name."
  (let [roots []
        seen {}
        start (path.cwd)
        physical (or (path.pwd-physical start) start)]
    (var cur physical)
    (var done? false)
    (while (not done?)
      (let [root (.. cur "/.fen/extensions")]
        (when (and (not (. seen root)) (path.dir-exists? root))
          (tset seen root true)
          (table.insert roots root)))
      (if (or (= cur "/") (marker-root? cur))
          (set done? true)
          (set cur (path.dirname cur))))
    roots))

(fn M.user-roots []
  "Roots that contain user-installed extensions: $FEN_EXTENSIONS_PATH (colon-
   separated explicit roots) and $XDG_CONFIG_HOME/fen/extensions. No project-
   local `fen/extensions` path is implied by user config discovery."
  (let [roots []]
    (each [_ p (ipairs (split-path-list (os.getenv :FEN_EXTENSIONS_PATH)))]
      (table.insert roots p))
    (table.insert roots (.. (path.config-home) "/fen/extensions"))
    roots))

(fn spec-from-dir [dir source]
  "Build a spec from a directory containing manifest.{fnl,lua} or init.{fnl,lua}.
   Returns nil if neither is present."
  (let [manifest-path (manifest-mod.manifest-path dir)
        fallback-entry (manifest-mod.entry-path-for-dir dir)]
    (when (or manifest-path fallback-entry)
      (let [manifest (manifest-mod.read-manifest manifest-path)
            name (or (?. manifest :name) (path.basename dir))
            first-party? (= source :first-party)]
        {:name (tostring name)
         :dir dir
         :manifest-path manifest-path
         :manifest manifest
         :source source
         :explicit? (= source :explicit)
         :first-party? first-party?}))))

(fn spec-from-single-file [file-path ?source]
  "Single-file extension: no manifest, the file itself is the entry. The
   extension's name is derived from the basename."
  (when (or (string.match file-path "%.fnl$")
            (string.match file-path "%.lua$"))
    (let [source (or ?source :explicit)]
      {:name (manifest-mod.strip-ext (path.basename file-path))
       :dir (path.dirname file-path)
       :manifest-path nil
       :manifest {}
       :entry-path file-path
       :source source
       :explicit? (= source :explicit)
       :first-party? false
       :project-local? (= source :project)})))

(fn spec-from-explicit-path [target]
  "Explicit --extension <path>: dir → manifest dir; file → single-file."
  (if (path.dir-exists? target) (spec-from-dir target :explicit)
      (path.file-exists? target) (spec-from-single-file target)
      nil))

(fn discover-from-roots [roots source ?yield-fn]
  (let [out []]
    (each [_ root (ipairs roots)]
      (when ?yield-fn (?yield-fn {:phase :extension-discover :root root}))
      (if (= source :first-party)
          (each [_ child (ipairs (manifest-dirs root ?yield-fn))]
            (let [spec (spec-from-dir child source)]
              (when spec (table.insert out spec))))
          (let [children (direct-children root ?yield-fn)
                dir-bases {}]
            ;; Directories win over same-basename single files, regardless of enumeration order.
            (each [_ child (ipairs children)]
              (let [base (path.basename child)]
                (when (and (not (hidden-or-disabled? base))
                           (path.dir-exists? child))
                  (tset dir-bases base true)
                  (let [spec (spec-from-dir child source)]
                    (when spec
                      (when (= source :project)
                        (tset spec :project-local? true))
                      (table.insert out spec))))))
            (each [_ child (ipairs children)]
              (let [base (path.basename child)
                    name (manifest-mod.strip-ext base)]
                (when (and (not (hidden-or-disabled? base))
                           (not (. dir-bases name))
                           (path.file-exists? child))
                  (let [spec (spec-from-single-file child source)]
                    (when spec (table.insert out spec)))))))))
    out))

(fn spec-from-embedded-manifest [module-name]
  "Build a first-party spec from an embedded manifest module. The single-file
   launcher can require modules from its ZIP archive, but discovery cannot walk
   that archive as a filesystem; this registry bridges that gap."
  (let [(ok? manifest) (pcall require module-name)]
    (when (and ok? (= (type manifest) :table))
      (let [name (or manifest.name
                     (string.match (tostring module-name)
                                   "^fen%.extensions%.([^%.]+)%.manifest$"))]
        {:name (tostring name)
         :dir (.. "embedded:" (tostring module-name))
         :manifest-path (.. "embedded:" (tostring module-name))
         :manifest manifest
         :source :first-party
         :first-party? true}))))

(fn discover-embedded-first-party []
  (let [out []]
    (each [_ module-name (ipairs embedded-first-party-manifests)]
      (let [spec (spec-from-embedded-manifest module-name)]
        (when spec (table.insert out spec))))
    out))

(fn M.enumerate [explicit-paths ?yield-fn]
  "Assemble the extension spec list from explicit paths and the filesystem/env
   roots, in load priority: explicit overrides trusted first-party flat
   overlays, which override project, user, and embedded first-party specs.
   Within each source, the first match found on disk wins. Specs are returned
   before name dedupe so the public discover module can apply its shared dedupe
   and version annotations regardless of backend."
  (let [specs []]
    (each [_ p (ipairs (or explicit-paths []))]
      (let [spec (spec-from-explicit-path p)]
        (if spec
            (table.insert specs spec)
            (log.warn (.. "extension: no manifest or .fnl/.lua entry at " p)))))
    (each [_ s (ipairs (discover-from-roots (M.first-party-roots) :first-party ?yield-fn))]
      (table.insert specs s))
    (each [_ s (ipairs (discover-from-roots (M.project-roots) :project ?yield-fn))]
      (table.insert specs s))
    (each [_ s (ipairs (discover-from-roots (M.user-roots) :user ?yield-fn))]
      (table.insert specs s))
    (each [_ s (ipairs (discover-embedded-first-party))]
      (table.insert specs s))
    specs))

M
