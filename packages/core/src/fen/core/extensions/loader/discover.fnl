;; Filesystem walk for extensions.
;;
;; Discovery is unified across first-party and external: every extension is
;; reached as a manifest dir found under some root, where the dir contains
;; a `manifest.{fnl,lua}` file. The loader consumes the spec list and decides
;; what to actually load.
;;
;; Roots come from three sources:
;;   - First-party convention: each prefix on `package.path` / `fennel.path`
;;     contributes `<prefix>/fen/extensions` if it exists. This finds packaged
;;     or rock-installed first-party extensions.
;;   - User config: `$FEN_EXTENSIONS_PATH`, `$XDG_CONFIG_HOME/fen/extensions`.
;;   - Explicit `--extension <path>`: a manifest dir, a single .fnl/.lua file,
;;     or any other path the user names.

(local path (require :fen.util.path))
(local log (require :fen.util.log))
(local manifest-mod (require :fen.core.extensions.loader.manifest))

(local M {})

(local embedded-first-party-manifests
  [:fen.extensions.agent_state.manifest
   :fen.extensions.builtin_commands.manifest
   :fen.extensions.builtin_tools.manifest
   :fen.extensions.default_prompt.manifest
   :fen.extensions.handoff.manifest
   :fen.extensions.mem.manifest
   :fen.extensions.print.manifest
   :fen.extensions.provider_anthropic.manifest
   :fen.extensions.provider_openai.manifest
   :fen.extensions.provider_openai_codex.manifest
   :fen.extensions.session_jsonl.manifest
   :fen.extensions.skills.manifest
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

(fn split-path-list [s]
  (let [out []]
    (when (and s (not= s ""))
      (each [part (string.gmatch s "[^:]+")]
        (when (not= part "")
          (table.insert out part))))
    out))

(fn search-path-prefixes [search-path]
  "Extract directory prefixes from a Lua/Fennel-style search path. An entry
   shaped `<prefix>/?.<ext>` or `<prefix>/?/init.<ext>` contributes <prefix>."
  (let [seen {}
        out []]
    (each [entry (string.gmatch (or search-path "") "[^;]+")]
      (let [prefix (or (string.match entry "^(.+)/%?%.[^/]+$")
                       (string.match entry "^(.+)/%?/init%.[^/]+$"))]
        (when (and prefix (not (. seen prefix)))
          (tset seen prefix true)
          (table.insert out prefix))))
    out))

(fn fennel-search-path []
  (let [(ok? fennel) (pcall require :fennel)]
    (if ok? (or fennel.path "") "")))

(fn M.first-party-roots []
  "Roots that contain rock-installed or dev-tree first-party extensions.
   Two shapes are honored:

   1. Namespaced layout — `<prefix>/fen/extensions/<snake>/manifest.{fnl,lua}`
      for each prefix extracted from package.path / fennel.path. Covers rock
      installs and any installed package set.

   2. Workspace flat layout — `<cwd>/extensions/<kebab>/manifest.{fnl,lua}`
      when the current working directory is a fen source checkout. Covers
      `make test` and dev runs from the workspace root before dist/ exists.
      Only fires when extensions/ exists relative to cwd, so it is
      a no-op for production invocations from arbitrary directories."
  (let [seen {}
        roots []
        prefixes []]
    (each [_ p (ipairs (search-path-prefixes package.path))]
      (table.insert prefixes p))
    (each [_ p (ipairs (search-path-prefixes (fennel-search-path)))]
      (table.insert prefixes p))
    (each [_ prefix (ipairs prefixes)]
      (let [root (.. prefix "/fen/extensions")]
        (when (and (not (. seen root)) (path.dir-exists? root))
          (tset seen root true)
          (table.insert roots root))))
    (let [flat "extensions"]
      (when (and (path.dir-exists? flat) (not (. seen flat)))
        (tset seen flat true)
        (table.insert roots flat)))
    roots))

(fn M.user-roots []
  "Roots that contain user-installed extensions: $FEN_EXTENSIONS_PATH (colon-
   separated) and $XDG_CONFIG_HOME/fen/extensions."
  (let [roots []]
    (each [_ p (ipairs (split-path-list (os.getenv :FEN_EXTENSIONS_PATH)))]
      (table.insert roots p))
    (table.insert roots (.. (path.config-home) "/fen/extensions"))
    roots))

(fn spec-from-dir [dir source]
  "Build a spec from a directory containing manifest.{fnl,lua}. Returns nil
   if no manifest is present."
  (let [manifest-path (manifest-mod.manifest-path dir)]
    (when manifest-path
      (let [manifest (manifest-mod.read-manifest manifest-path)
            name (or (?. manifest :name) (path.basename dir))
            first-party? (or (= source :first-party)
                             (manifest-mod.first-party? manifest))]
        {:name (tostring name)
         :dir dir
         :manifest-path manifest-path
         :manifest manifest
         :source source
         :explicit? (= source :explicit)
         :first-party? first-party?}))))

(fn spec-from-single-file [file-path]
  "Single-file extension: no manifest, the file itself is the entry. The
   extension's name is derived from the basename. The empty manifest passes
   through `enabled?` because :explicit? is true."
  (when (or (string.match file-path "%.fnl$")
            (string.match file-path "%.lua$"))
    {:name (manifest-mod.strip-ext (path.basename file-path))
     :dir (path.dirname file-path)
     :manifest-path nil
     :manifest {}
     :entry-path file-path
     :source :explicit
     :explicit? true
     :first-party? false}))

(fn spec-from-explicit-path [target]
  "Explicit --extension <path>: dir → manifest dir; file → single-file."
  (if (path.dir-exists? target) (spec-from-dir target :explicit)
      (path.file-exists? target) (spec-from-single-file target)
      nil))

(fn discover-from-roots [roots source]
  (let [out []]
    (each [_ root (ipairs roots)]
      (each [_ child (ipairs (direct-children root))]
        (let [base (path.basename child)]
          (when (and (not (hidden-or-disabled? base))
                     (path.dir-exists? child))
            (let [spec (spec-from-dir child source)]
              (when spec (table.insert out spec)))))))
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

(fn M.discover [explicit-paths]
  "Return the merged spec list in load priority: explicit overrides user
   overrides first-party. Within each source, the first match found on disk
   wins."
  (let [specs []]
    (each [_ p (ipairs (or explicit-paths []))]
      (let [spec (spec-from-explicit-path p)]
        (if spec
            (table.insert specs spec)
            (log.warn (.. "extension: no manifest or .fnl/.lua entry at " p)))))
    (each [_ s (ipairs (discover-from-roots (M.user-roots) :user))]
      (table.insert specs s))
    (each [_ s (ipairs (discover-from-roots (M.first-party-roots) :first-party))]
      (table.insert specs s))
    (each [_ s (ipairs (discover-embedded-first-party))]
      (table.insert specs s))
    (dedupe-by-name! specs)))

M
