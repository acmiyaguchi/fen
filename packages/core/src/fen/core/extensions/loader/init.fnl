;; Extension bootstrap / loader.
;;
;; Discovery is unified: every external extension is reached as a direct child
;; of an explicit, project, or user root. Project auto-discovery uses only
;; dot-prefixed cwd/ancestor `.fen/extensions`; user-global auto-discovery uses
;; `$XDG_CONFIG_HOME/fen/extensions` (`~/.config/fen/extensions` by default).
;; `$FEN_EXTENSIONS_PATH` and `--extension <path>` are explicit escape hatches.
;; Internal first-party extensions are discovered from
;; the embedded manifest registry, not by walking `fen/extensions` on disk or
;; deriving roots from `package.path` / `fennel.path`.
;;
;; A manifest declares its own entry point:
;;   :entry-module — Lua module name resolved through the searcher chain.
;;                   The module body runs at require time and self-registers
;;                   (`(api.register …)`) before returning.
;;   :entry        — file path relative to the manifest dir. The file is
;;                   dofile'd; its return value is a register fn or
;;                   `{:register fn}` and the loader calls it with the api.
;;
;; If neither is set, the loader falls back to <dir>/init.{fnl,lua} as the
;; path-shaped entry. The `fen.extensions.*` namespace is a convention for
;; first-party rocks, not a structural requirement: third-party rocks may
;; pick any namespace, and project-local drop-ins use no namespace at all.
;;
;; Mechanics live in three sibling modules so this file stays orchestration:
;;   - core.extensions.loader.manifest  — manifest reading + entry-file loading
;;   - core.extensions.loader.discover  — root walking + spec construction
;;   - core.extensions.loader.reload    — per-module fingerprint tracking

(local state (require :fen.core.extensions.state))
(local register-registry (require :fen.core.extensions.register))
(local events (require :fen.core.extensions.events))
(local ext-api (require :fen.core.extensions.api))
(local log (require :fen.util.log))
(local manifest-mod (require :fen.core.extensions.loader.manifest))
(local discover (require :fen.core.extensions.loader.discover))
(local reload (require :fen.core.extensions.loader.reload))
(local rocks (require :fen.core.extensions.rocks))

(local M {})

(local loaded {})

(fn record-spec-status! [spec status extra]
  (let [rec {:manifest spec.manifest :status status
             :path (or spec.entry-path spec.manifest-path spec.dir)
             :source spec.source
             :version-count (or spec.version-count 1)
             :versions (or spec.versions [])
             :first-party? (or spec.first-party? false)}]
    (each [k v (pairs (or extra {}))] (tset rec k v))
    (tset state.extensions spec.name rec)))

(fn actionable-error [spec err]
  (let [missing (rocks.parse-missing-module err)]
    (if missing
        (rocks.missing-module-message spec missing)
        err)))

(fn record-spec-error! [spec err]
  ;; Tear down any partial batch before recording the failure so an errored
  ;; extension cannot leave half-active presenters/commands/handlers behind.
  (register-registry.unregister-by-owner spec.name)
  (let [display-err (actionable-error spec err)]
    (record-spec-status! spec :error {:error (tostring display-err)})
    (log.warn (.. "extension " spec.name " failed: " (tostring display-err)))))

(fn try-register-entry! [spec entry]
  "Validate the loaded entry shape and call its register fn under pcall.
   Returns (true nil) on success or (false err) on failure."
  (let [register (manifest-mod.entry-register entry)]
    (if (not (= (type register) :function))
        (values false "entry must return function or {:register fn}")
        (let [api (ext-api.make-api spec.name spec.manifest)
              api-with-load (doto api
                              (tset :load
                                    (fn [sibling]
                                      (M.load-sibling spec sibling))))
              (ok? reg-err) (pcall register api-with-load)]
          (if ok? (values true nil) (values false reg-err))))))

(fn load-module-spec! [spec opts]
  "Module-shaped extension: require the entry module. The loader drops prior
   owner-tagged contributions FIRST so extension bodies don't need explicit
   unregister-by-owner boilerplate. On reload, clear `:reload-modules` from
   package.loaded so the re-require re-runs every body that owns behavior.
   Order matters: clearing/requiring installs the new registrations — calling
   unregister-by-owner *after* it would wipe the registrations that just
   landed, leaving state.presenters / commands-extra empty."
  (let [entry-module (manifest-mod.entry-module-of spec.manifest)]
    (register-registry.unregister-by-owner spec.name)
    (when (and (not opts.reload?) (. package.loaded entry-module))
      (tset package.loaded entry-module nil))
    (let [changes (if opts.reload?
                      (reload.clear-reload-modules! spec.manifest [entry-module])
                      (reload.change-summary
                        (manifest-mod.reload-modules spec.manifest [entry-module])))
          (ok? entry-or-err) (pcall require entry-module)]
      (if ok?
          (let [register (manifest-mod.entry-register entry-or-err)
                (reg-ok? reg-err) (if register
                                      (try-register-entry! spec entry-or-err)
                                      (values true nil))]
            (if reg-ok?
                (do
                  (record-spec-status! spec :loaded {})
                  (tset loaded spec.name spec)
                  (events.emit {:type :extension-loaded :name spec.name})
                  (values true nil changes))
                (let [display-err (actionable-error spec reg-err)]
                  (record-spec-error! spec reg-err)
                  (values false display-err changes))))
          (do
            (let [display-err (actionable-error spec entry-or-err)]
              (record-spec-error! spec entry-or-err)
              (values false display-err changes)))))))

(fn load-path-spec! [spec _opts]
  "Path-shaped extension: dofile the entry, call its register fn with the api."
  (register-registry.unregister-by-owner spec.name)
  (let [changes (reload.change-summary (manifest-mod.reload-modules spec.manifest []))
        entry-path (or spec.entry-path
                       (let [manifest-entry (manifest-mod.entry-of spec.manifest)]
                         (if manifest-entry
                             (.. spec.dir "/" manifest-entry)
                             (manifest-mod.entry-path-for-dir spec.dir))))]
    (if (not entry-path)
        (let [err (.. "no entry: set :entry-module or :entry, or place "
                      "init.{fnl,lua} in " spec.dir)]
          (record-spec-error! spec err)
          (values false err changes))
        (do
          (when (reload.file-changed?! entry-path)
            (set changes.checked (+ changes.checked 1))
            (set changes.changed (+ changes.changed 1))
            (table.insert changes.changed-modules entry-path))
          (let [(entry load-err) (manifest-mod.load-file entry-path)]
            (if load-err
                (let [display-err (actionable-error spec load-err)]
                  (record-spec-error! spec load-err)
                  (values false display-err changes))
                (let [(reg-ok? reg-err) (try-register-entry! spec entry)]
                  (if reg-ok?
                      (do (record-spec-status! spec :loaded {})
                          (tset loaded spec.name spec)
                          (events.emit {:type :extension-loaded :name spec.name})
                          (values true nil changes))
                      (let [display-err (actionable-error spec reg-err)]
                        (record-spec-error! spec reg-err)
                        (values false display-err changes))))))))))

(fn presenter-match? [spec opts]
  "True when the spec has no presenter, or its presenter matches opts."
  (let [p (manifest-mod.presenter-of spec.manifest)]
    (or (not p) (= p (or opts.presenter :tui)))))

(fn admissible? [spec opts]
  "Gate that decides whether to even consider the spec at this run mode.
   Disabled specs still pass through so the loader records them with
   :disabled status; load-spec-with-status! is the one that short-circuits
   them before invoking the entry."
  (and (or (not (manifest-mod.interactive-only? spec.manifest))
           opts.interactive?)
       (presenter-match? spec opts)))

(fn load-spec! [spec opts]
  (if (manifest-mod.entry-module-of spec.manifest)
      (load-module-spec! spec opts)
      (load-path-spec! spec opts)))

(fn load-spec-with-status! [spec opts]
  "Run admissibility checks, then load. Returns a summary entry suitable for
   the global summary list."
  (if (not (manifest-mod.enabled? spec))
      (do (record-spec-status! spec :disabled {})
          {:name spec.name :status :disabled :checked 0 :changed 0
           :changed-modules [] :source spec.source
           :version-count (or spec.version-count 1)
           :versions (or spec.versions [])
           :first-party? spec.first-party?})
      (let [declared-missing (manifest-mod.missing-requires-modules spec.manifest)]
        (if (> (length declared-missing) 0)
            (let [err (rocks.missing-modules-message spec declared-missing)]
              (record-spec-error! spec err)
              {:name spec.name :status :error :error (tostring err)
               :checked 0 :changed 0 :changed-modules [] :source spec.source
               :version-count (or spec.version-count 1)
               :versions (or spec.versions [])
               :first-party? spec.first-party?})
            (let [missing (manifest-mod.missing-deps spec.manifest)]
              (if (> (length missing) 0)
                  (do (record-spec-status! spec :missing-deps {:missing missing})
                      (log.warn (.. "extension " spec.name " disabled; missing "
                                    (table.concat missing ", ")))
                      {:name spec.name :status :missing-deps :checked 0 :changed 0
                       :changed-modules [] :source spec.source
                       :version-count (or spec.version-count 1)
                       :versions (or spec.versions [])
                       :first-party? spec.first-party?})
                  (let [(ok? err changes) (load-spec! spec opts)]
                    {:name spec.name
                     :status (if ok? :loaded :error)
                     :error (if (not ok?) (tostring err))
                     :checked (or (?. changes :checked) 0)
                     :changed (or (?. changes :changed) 0)
                     :changed-modules (or (?. changes :changed-modules) [])
                     :source spec.source
                     :version-count (or spec.version-count 1)
                     :versions (or spec.versions [])
                     :first-party? spec.first-party?})))))))

(fn first-party-failure-message [failures]
  (let [parts []]
    (each [_ f (ipairs failures)]
      (table.insert parts (.. (tostring f.name) ": " (tostring f.error))))
    (.. "first-party extension load failed: " (table.concat parts "; "))))

;; @doc fen.core.extensions.loader.load-sibling
;; kind: function
;; signature: (load-sibling spec sibling) -> any
;; summary: Load a sibling .fnl/.lua file for a path-shaped extension's api.load helper without requiring a global namespace.
;; tags: extensions loader files
(fn M.load-sibling [spec sibling]
  "Load a sibling file relative to spec.dir. Used by `(api.load :name)` from
   path-shaped extensions to import sibling helpers without a global namespace.
   Looks for <dir>/<sibling>.fnl then <dir>/<sibling>.lua."
  (let [base (.. spec.dir "/" (tostring sibling))
        candidates [(.. base ".fnl") (.. base ".lua") base]
        path-mod (require :fen.util.path)]
    (var found nil)
    (each [_ candidate (ipairs candidates)]
      (when (and (not found) (path-mod.file-exists? candidate))
        (set found candidate)))
    (if (not found)
        (error (.. "extension " spec.name ": cannot load sibling " (tostring sibling)))
        (let [(value err) (manifest-mod.load-file found)]
          (if err (error err) value)))))

;; @doc fen.core.extensions.loader.load!
;; kind: function
;; signature: (load! opts ?mode) -> ExtensionLoadSummary
;; summary: Discover, gate, and load admissible extensions, failing fast only after collecting first-party load failures.
;; tags: extensions loader lifecycle
(fn M.load! [opts ?mode]
  "Discover and load every admissible extension. First-party extensions
   fail-fast: a load error raises after the pass collecting all failures."
  (let [mode (or ?mode {})
        opts (or opts {})
        discover-opts {:interactive? (if (= mode.interactive? nil) true mode.interactive?)
                       :presenter (or opts.presenter :tui)
                       :reload? mode.reload?}
        specs (discover.discover (or opts.extension-paths []))
        summaries []
        first-party-failures []]
    (each [_ spec (ipairs specs)]
      (when (admissible? spec discover-opts)
        (let [summary (load-spec-with-status! spec discover-opts)]
          (table.insert summaries summary)
          (when (and spec.first-party? (= summary.status :error))
            (table.insert first-party-failures
                          {:name spec.name :error summary.error})))))
    (when (> (length first-party-failures) 0)
      (error (first-party-failure-message first-party-failures)))
    (M.summarize summaries)))

;; @doc fen.core.extensions.loader.summarize
;; kind: function
;; signature: (summarize items) -> ExtensionLoadSummary
;; summary: Fold per-extension load entries into aggregate loaded/changed/failed counters plus the original extension list.
;; tags: extensions loader diagnostics
(fn M.summarize [items]
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

;; @doc fen.core.extensions.loader.reload-extension!
;; kind: function
;; signature: (reload-extension! name) -> ok?, err
;; summary: Reload a previously loaded extension by name using its retained spec and interactive TUI reload mode.
;; tags: extensions loader reload
(fn M.reload-extension! [name]
  (let [spec (. loaded name)]
    (if spec
        (let [opts {:interactive? true :presenter :tui :reload? true}]
          (let [(ok? err _changes) (load-spec! spec opts)]
            (values ok? err)))
        (values false (.. "extension not loaded: " (tostring name))))))

M
