;; Extension bootstrap / loader (issue #15 Step 5).
;;
;; First-party bundled extensions are just modules in this namespace. External
;; extensions are loaded from explicit `--extension <path>` entries plus the
;; configured search roots. External entry modules return either a function
;; `(fn [api] ...)` or a table with `:register`.

(local core-ext (require :core.extensions))
(local state (require :core.extensions.state))
(local checksum (require :util.checksum))
(local log (require :util.log))

(local M {})

(local BUILTIN-EXTENSIONS
  [{:entry :extensions.builtin_tools
    :manifest-module :extensions.builtin_tools.manifest}
   {:entry :extensions.builtin_commands
    :manifest-module :extensions.builtin_commands.manifest}
   {:entry :extensions.agent_state
    :manifest-module :extensions.agent_state.manifest}
   {:entry :extensions.tui
    :manifest-module :extensions.tui.manifest
    ;; Presenter/termbox extension: only meaningful in interactive mode.
    ;; Tool-only first-party extensions can omit this flag so they load for
    ;; both --print and interactive runs.
    :interactive-only? true}])

(local loaded {})

(fn dirname [path]
  (or (string.match path "^(.*)/[^/]*$") "."))

(fn basename [path]
  (or (string.match path "([^/]+)/?$") path))

(fn strip-ext [name]
  (or (string.match name "^(.*)%.fnl$")
      (string.match name "^(.*)%.lua$")
      name))

(fn hidden-or-disabled? [name]
  (let [c (string.sub name 1 1)]
    (or (= c ".") (= c "_"))))

(fn file-exists? [path]
  (let [f (io.open path :r)]
    (when f (f:close))
    (not= f nil)))

(fn shellquote [s]
  (.. "'" (string.gsub (tostring s) "'" "'\\''") "'"))

(fn command-output-lines [cmd]
  (let [p (io.popen cmd)
        out []]
    (when p
      (each [line (p:lines)]
        (table.insert out line))
      (p:close))
    out))

(fn dir? [path]
  (let [lines (command-output-lines
                (.. "[ -d " (shellquote path) " ] && printf yes"))]
    (= (. lines 1) "yes")))

(fn direct-children [dir]
  (if (not (dir? dir))
      []
      (command-output-lines
        (.. "find " (shellquote dir)
            " -mindepth 1 -maxdepth 1 -print"))))

(fn split-path-list [s]
  (let [out []]
    (when (and s (not= s ""))
      (each [part (string.gmatch s "[^:]+")]
        (when (not= part "")
          (table.insert out part))))
    out))

(fn home [] (or (os.getenv :HOME) "."))

(fn config-home []
  (or (os.getenv :XDG_CONFIG_HOME)
      (.. (home) "/.config")))

(fn candidate-roots []
  (let [roots []]
    (each [_ p (ipairs (split-path-list (os.getenv :FEN_EXTENSIONS_PATH)))]
      (table.insert roots p))
    (table.insert roots (.. (config-home) "/fen/extensions"))
    ;; Compatibility with the project name used elsewhere in this repo.
    (table.insert roots (.. (config-home) "/agent-fennel/extensions"))
    roots))

(fn load-fnl-file [path]
  (let [(ok? fennel) (pcall require :fennel)]
    (if (not ok?)
        (values nil (.. "cannot load Fennel extension without fennel module: "
                        (tostring fennel)))
        (let [(ok2 result) (pcall fennel.dofile path)]
          (if ok2 (values result nil) (values nil result))))))

(fn load-lua-file [path]
  (let [(ok? result) (pcall dofile path)]
    (if ok? (values result nil) (values nil result))))

(fn load-file [path]
  (if (string.match path "%.fnl$")
      (load-fnl-file path)
      (load-lua-file path)))

(fn manifest-path [dir]
  (let [fnl-path (.. dir "/manifest.fnl")
        lua-path (.. dir "/manifest.lua")]
    (if (file-exists? fnl-path) fnl-path
        (file-exists? lua-path) lua-path
        nil)))

(fn entry-path-for-dir [dir]
  (let [fnl-path (.. dir "/init.fnl")
        lua-path (.. dir "/init.lua")]
    (if (file-exists? fnl-path) fnl-path
        (file-exists? lua-path) lua-path
        nil)))

(fn read-manifest [path]
  (if path
      (let [(m err) (load-file path)]
        (if (and (not err) (= (type m) :table)) m {}))
      {}))

(fn read-manifest-module [modname]
  (if modname
      (let [(ok? m) (pcall require modname)]
        (if (and ok? (= (type m) :table)) m {}))
      {}))

(fn spec-from-path [path explicit?]
  (let [is-dir? (dir? path)
        entry (if is-dir? (entry-path-for-dir path) path)
        manifest (if is-dir? (read-manifest (manifest-path path)) {})]
    (when (and entry
               (or (string.match entry "%.fnl$")
                   (string.match entry "%.lua$")))
      (let [name (or manifest.name
                     (if is-dir? (basename path) (strip-ext (basename path))))]
        {:name name
         :path path
         :entry entry
         :dir (if is-dir? path (dirname path))
         :manifest manifest
         :explicit? explicit?}))))

(fn discover-external [explicit-paths]
  (let [out []]
    (each [_ root (ipairs (candidate-roots))]
      (each [_ child (ipairs (direct-children root))]
        (let [base (basename child)]
          (when (not (hidden-or-disabled? base))
            (let [spec (spec-from-path child false)]
              (when spec (table.insert out spec)))))))
    (each [_ p (ipairs (or explicit-paths []))]
      (let [spec (spec-from-path p true)]
        (if spec
            (table.insert out spec)
            (log.warn (.. "extension: no init.fnl/init.lua at " p)))))
    out))

(fn command-exists? [cmd]
  (let [lines (command-output-lines
                (.. "command -v " (shellquote cmd) " >/dev/null 2>&1 && printf yes"))]
    (= (. lines 1) "yes")))

(fn list-has? [xs x]
  (var found false)
  (each [_ v (ipairs (or xs []))]
    (when (= v x) (set found true)))
  found)

(fn manifest-reload-modules [manifest fallback]
  (or manifest.reload-modules
      manifest.reloadModules
      fallback
      []))

(fn manifest-reload-exclude [manifest]
  (or manifest.reload-exclude
      manifest.reloadExclude
      []))

(fn fp-cache []
  (when (not state.reload-fingerprints)
    (set state.reload-fingerprints {}))
  state.reload-fingerprints)

(fn changed-fingerprint?! [key fp]
  (if (not fp)
      false
      (let [cache (fp-cache)
            old (. cache key)]
        (tset cache key fp.fingerprint)
        (and old (not= old fp.fingerprint)))))

(fn module-changed?! [modname]
  (changed-fingerprint?! (.. "module:" (tostring modname))
                         (checksum.module-fingerprint modname)))

(fn file-changed?! [path]
  (changed-fingerprint?! (.. "file:" (tostring path))
                         (checksum.file-fingerprint path)))

(fn change-summary [mods]
  (let [summary {:checked 0 :changed 0 :changed-modules []}]
    (each [_ modname (ipairs (or mods []))]
      (set summary.checked (+ summary.checked 1))
      (when (module-changed?! modname)
        (set summary.changed (+ summary.changed 1))
        (table.insert summary.changed-modules modname)))
    summary))

(fn clear-reload-modules! [manifest fallback]
  (let [mods (manifest-reload-modules manifest fallback)
        excluded (manifest-reload-exclude manifest)
        summary (change-summary mods)]
    (each [_ modname (ipairs mods)]
      (when (not (list-has? excluded modname))
        (tset package.loaded modname nil)))
    summary))

(fn missing-deps [manifest]
  (let [missing []
        req (or manifest.requires {})
        lua-req (or req.lua [])
        bin-req (or req.bin [])]
    (each [_ mod (ipairs lua-req)]
      (let [(ok? _err) (pcall require mod)]
        (when (not ok?)
          (table.insert missing (.. "lua:" (tostring mod))))))
    (each [_ bin (ipairs bin-req)]
      (when (not (command-exists? bin))
        (table.insert missing (.. "bin:" (tostring bin)))))
    missing))

(fn enabled? [spec]
  (or spec.explicit?
      (= spec.manifest.enabled-by-default true)))

(fn entry-register [entry]
  (if (= (type entry) :function) entry
      (= (type entry) :table) entry.register
      nil))

(fn load-builtin-spec! [spec reload?]
  (let [manifest (read-manifest-module spec.manifest-module)
        name (or manifest.name spec.name spec.entry)
        changes (if reload?
                    (do
                      (core-ext.unregister-by-owner name)
                      (clear-reload-modules! manifest [spec.entry]))
                    (change-summary (manifest-reload-modules manifest [spec.entry])))]
    (let [(ok? err) (pcall require spec.entry)]
      (if ok?
          (do
            (core-ext.record-extension!
              name {:manifest manifest :status :loaded :path (tostring spec.entry)
                    :first-party? true})
            (core-ext.emit {:type :extension-loaded :name name})
            (values true nil name changes))
          (do
            ;; A module-load error may happen after the extension has already
            ;; registered some side effects. Tear down that partial batch before
            ;; recording the failure so an errored first-party extension cannot
            ;; leave a half-active presenter/command/handler behind.
            (core-ext.unregister-by-owner name)
            (core-ext.record-extension!
              name {:manifest manifest :status :error :path (tostring spec.entry)
                    :first-party? true :error (tostring err)})
            (log.warn (.. "first-party extension " (tostring name)
                          " failed: " (tostring err)))
            (values false err name changes))))))

(fn builtin-failure-message [failures]
  (let [parts []]
    (each [_ f (ipairs failures)]
      (table.insert parts (.. (tostring f.name) ": " (tostring f.error))))
    (.. "first-party extension load failed: " (table.concat parts "; "))))

(fn M.load-builtins! [?opts]
  (let [opts (or ?opts {})
        ;; Direct calls default to interactive for backward compatibility with
        ;; tests and with the old "load the TUI builtin" behavior. M.load!
        ;; passes an explicit mode so --print can still load non-presenter
        ;; builtins without touching termbox.
        interactive? (if (= opts.interactive? nil) true opts.interactive?)
        failures []
        summaries []]
    (each [_ spec (ipairs BUILTIN-EXTENSIONS)]
      (when (or (not spec.interactive-only?) interactive?)
        (let [(ok? err name changes) (load-builtin-spec! spec opts.reload?)]
          (table.insert summaries {:name name
                                   :status (if ok? :loaded :error)
                                   :changed (or (?. changes :changed) 0)
                                   :checked (or (?. changes :checked) 0)
                                   :changed-modules (or (?. changes :changed-modules) [])
                                   :first-party? true})
          (when (not ok?)
            (table.insert failures {:name name :error err})))))
    (when (> (length failures) 0)
      (error (builtin-failure-message failures)))
    summaries))

(fn load-external-spec! [spec]
  ;; Always tear down the previous contribution batch first. This makes
  ;; /reload and /reload-extension safe when an extension becomes disabled,
  ;; loses a dependency, or fails during registration.
  (core-ext.unregister-by-owner spec.name)
  (let [changes (change-summary (manifest-reload-modules spec.manifest []))]
    (when (file-changed?! spec.entry)
      (set changes.checked (+ changes.checked 1))
      (set changes.changed (+ changes.changed 1))
      (table.insert changes.changed-modules spec.entry))
  (if (not (enabled? spec))
      (do
        (core-ext.record-extension!
          spec.name {:manifest spec.manifest :status :disabled :path spec.path})
        (values false :disabled changes))
      (let [missing (missing-deps spec.manifest)]
        (if (> (length missing) 0)
            (do
              (core-ext.record-extension!
                spec.name {:manifest spec.manifest :status :missing-deps
                           :path spec.path :missing missing})
              (log.warn (.. "extension " spec.name " disabled; missing "
                            (table.concat missing ", ")))
              (values false :missing-deps changes))
            (do
              (clear-reload-modules! spec.manifest [])
              (tset package.loaded spec.entry nil)
              (let [(entry err) (load-file spec.entry)]
                (if err
                    (do
                      (core-ext.unregister-by-owner spec.name)
                      (core-ext.record-extension!
                        spec.name {:manifest spec.manifest :status :error
                                   :path spec.path :error (tostring err)})
                      (log.warn (.. "extension " spec.name " failed: "
                                    (tostring err)))
                      (values false err changes))
                    (let [register (entry-register entry)]
                      (if (not (= (type register) :function))
                          (let [msg "entry must return function or {:register fn}"]
                            (core-ext.unregister-by-owner spec.name)
                            (core-ext.record-extension!
                              spec.name {:manifest spec.manifest :status :error
                                         :path spec.path :error msg})
                            (values false msg changes))
                          (let [api (core-ext.make-api spec.name spec.manifest)
                                (ok? reg-err) (pcall register api)]
                            (if ok?
                                (do
                                  (core-ext.record-extension!
                                    spec.name {:manifest spec.manifest
                                               :status :loaded :path spec.path})
                                  (tset loaded spec.name spec)
                                  (core-ext.emit {:type :extension-loaded
                                                  :name spec.name})
                                  (values true nil changes))
                                (do
                                  (core-ext.unregister-by-owner spec.name)
                                  (core-ext.record-extension!
                                    spec.name {:manifest spec.manifest
                                               :status :error :path spec.path
                                               :error (tostring reg-err)})
                                  (values false reg-err changes))))))))))))))

(fn M.load-external! [opts]
  (let [seen {}
        summaries []]
    (each [_ spec (ipairs (discover-external (or opts.extension-paths [])))]
      (if (. seen spec.name)
          (log.warn (.. "extension " spec.name " skipped; duplicate name"))
          (do
            (tset seen spec.name true)
            (let [(ok? err changes) (load-external-spec! spec)]
              (table.insert summaries {:name spec.name
                                       :status (if ok? :loaded err)
                                       :changed (or (?. changes :changed) 0)
                                       :checked (or (?. changes :checked) 0)
                                       :changed-modules (or (?. changes :changed-modules) [])
                                       :first-party? false})))) )
    summaries))

(fn summarize-load [items]
  (let [summary {:extensions [] :loaded 0 :changed 0 :failed 0}]
    (each [_ item (ipairs (or items []))]
      (table.insert summary.extensions item)
      (when (= item.status :loaded)
        (set summary.loaded (+ summary.loaded 1)))
      (when (> (or item.changed 0) 0)
        (set summary.changed (+ summary.changed 1)))
      (when (not= item.status :loaded)
        (set summary.failed (+ summary.failed 1))))
    summary))

(fn M.load! [opts ?mode]
  (let [mode (or ?mode {})
        builtins (M.load-builtins! {:reload? mode.reload?
                                    :interactive? mode.interactive?})
        external (M.load-external! (or opts {}))
        all []]
    (each [_ item (ipairs (or builtins []))] (table.insert all item))
    (each [_ item (ipairs (or external []))] (table.insert all item))
    (summarize-load all)))

(fn M.reload-extension! [name]
  (let [spec (. loaded name)]
    (if spec
        (load-external-spec! spec)
        (values false (.. "extension not loaded: " (tostring name))))))

M
