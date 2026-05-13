;; Filesystem walk for extensions.
;;
;; Filesystem discovery is unified across explicit, project, and user roots:
;; every external extension is reached as a direct child of a known root.
;; Directory children may carry a `manifest.{fnl,lua}` or just an
;; `init.{fnl,lua}` entry; single-file children may be `.fnl`/`.lua` entries.
;; Internal first-party discovery is separate and uses the embedded manifest
;; registry below. The loader consumes the spec list and decides what to
;; actually load.
;;
;; Roots come from three external sources plus one internal source:
;;   - Explicit `--extension <path>`: a manifest dir, a single .fnl/.lua file,
;;     or any other path the user names.
;;   - Project-local: `.fen/extensions` in cwd and ancestors up to the
;;     worktree root (or filesystem root if no marker is found).
;;   - First-party flat overlays: `$FEN_FIRST_PARTY_EXTENSIONS_PATH`, populated
;;     by the single-file launcher from `--extension-root` / `$FEN_EXTENSION_ROOT`.
;;   - User config: `$FEN_EXTENSIONS_PATH` roots and `$XDG_CONFIG_HOME/fen/extensions`.
;;   - Internal first-party: known manifest modules required from the embedded
;;     runtime ZIP / module searchers.
;;
;; Important policy: filesystem auto-discovery never treats project-local
;; `fen/extensions` as special. Project drop-ins live under dot-prefixed
;; `.fen/extensions`; user-global drop-ins live under the XDG config root
;; (`~/.config/fen/extensions` by default), or under roots explicitly named by
;; env/CLI. First-party bundled extensions are discovered from the embedded
;; manifest registry below rather than by walking
;; `package.path` / `fennel.path`; this prevents a random cwd checkout at
;; `./fen/extensions` from becoming an implicit trusted extension root.

(local path (require :fen.util.path))
(local log (require :fen.util.log))
(local manifest-mod (require :fen.core.extensions.loader.manifest))

(local M {})

(local embedded-first-party-manifests
  [:fen.extensions.agent_state.manifest
   :fen.extensions.builtin_tools.manifest
   :fen.extensions.default_prompt.manifest
   :fen.extensions.docs.manifest
   :fen.extensions.essentials.manifest
   :fen.extensions.extensions_inspector.manifest
   :fen.extensions.compact.manifest
   :fen.extensions.handoff.manifest
   :fen.extensions.mem.manifest
   :fen.extensions.todo.manifest
   :fen.extensions.print.manifest
   :fen.extensions.prompt.manifest
   :fen.extensions.provider_anthropic.manifest
   :fen.extensions.provider_openai.manifest
   :fen.extensions.queue.manifest
   :fen.extensions.session_jsonl.manifest
   :fen.extensions.sessions.manifest
   :fen.extensions.skills.manifest
   :fen.extensions.status.manifest
   :fen.extensions.stdio.manifest
   :fen.extensions.tui.manifest
   :fen.extensions.web.manifest])

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

(fn manifest-dirs [dir]
  (if (not (path.dir-exists? dir))
      []
      (let [seen {}
            out []]
        (each [_ file (ipairs (command-output-lines
                                (.. "find " (path.shell-quote dir)
                                    " -type f \\( -name manifest.fnl -o -name manifest.lua \\) -print")))]
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

;; @doc fen.core.extensions.loader.discover.first-party-roots
;; kind: function
;; signature: (first-party-roots) -> [string]
;; summary: Return trusted flat first-party overlay roots supplied by the single-file launcher.
;; tags: extensions loader discovery
(fn M.first-party-roots []
  "Return trusted flat first-party overlay roots.

   First-party/bundled extensions are discovered by requiring the fixed
   embedded manifest module registry below. Development checkouts can override
   those bundled modules through the single-file launcher's `--extension-root`
   / `$FEN_EXTENSION_ROOT`; the launcher exposes those roots here as trusted
   flat first-party overlays and installs the flat-extension module searcher."
  (split-path-list (os.getenv :FEN_FIRST_PARTY_EXTENSIONS_PATH)))

;; @doc fen.core.extensions.loader.discover.project-roots
;; kind: function
;; signature: (project-roots) -> [string]
;; summary: Return .fen/extensions roots from cwd upward to the worktree boundary, nearest first for project-local override priority.
;; tags: extensions loader discovery
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

;; @doc fen.core.extensions.loader.discover.user-roots
;; kind: function
;; signature: (user-roots) -> [string]
;; summary: Return user extension roots from FEN_EXTENSIONS_PATH plus the XDG fen/extensions directory.
;; tags: extensions loader discovery
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

(fn discover-from-roots [roots source]
  (let [out []]
    (each [_ root (ipairs roots)]
      (if (= source :first-party)
          (each [_ child (ipairs (manifest-dirs root))]
            (let [spec (spec-from-dir child source)]
              (when spec (table.insert out spec))))
          (let [children (direct-children root)
                dir-bases {}]
            ;; Directories win over same-basename single files, independent of
            ;; filesystem enumeration order.
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

(fn spec-path [spec]
  (or spec.entry-path spec.manifest-path spec.dir))

(fn dedupe-by-name! [specs]
  "First spec for a given name wins. The caller assembles specs in priority
   order — most authoritative first — so the first match is the right one.
   Each retained spec is annotated with :version-count and :versions, the
   discovered candidates with the same extension name before priority dedupe.
   This lets `/extensions` surface shadowed external/bundled copies."
  (let [versions {}
        seen {}
        out []]
    (each [_ spec (ipairs specs)]
      (when (not (. versions spec.name))
        (tset versions spec.name []))
      (table.insert (. versions spec.name)
                    {:path (spec-path spec)
                     :source spec.source
                     :first-party? spec.first-party?
                     :active? false}))
    (each [_ spec (ipairs specs)]
      (when (not (. seen spec.name))
        (tset seen spec.name true)
        (let [items (or (. versions spec.name) [])]
          (when (. items 1)
            (tset (. items 1) :active? true))
          (tset spec :versions items)
          (tset spec :version-count (length items)))
        (table.insert out spec)))
    out))

;; @doc fen.core.extensions.loader.discover.discover
;; kind: function
;; signature: (discover explicit-paths) -> [ExtensionSpec]
;; summary: Build the deduped extension spec list in load-priority order: explicit, first-party flat overlays, project, user, then embedded first-party.
;; tags: extensions loader discovery
(fn M.discover [explicit-paths]
  "Return the merged spec list in load priority: explicit overrides trusted
   first-party flat overlays, which override project, user, and embedded
   first-party specs. Within each source, the first match found on disk wins."
  (let [specs []]
    (each [_ p (ipairs (or explicit-paths []))]
      (let [spec (spec-from-explicit-path p)]
        (if spec
            (table.insert specs spec)
            (log.warn (.. "extension: no manifest or .fnl/.lua entry at " p)))))
    (each [_ s (ipairs (discover-from-roots (M.first-party-roots) :first-party))]
      (table.insert specs s))
    (each [_ s (ipairs (discover-from-roots (M.project-roots) :project))]
      (table.insert specs s))
    (each [_ s (ipairs (discover-from-roots (M.user-roots) :user))]
      (table.insert specs s))
    (each [_ s (ipairs (discover-embedded-first-party))]
      (table.insert specs s))
    (dedupe-by-name! specs)))

M
