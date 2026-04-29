;; Extension bootstrap / loader (issue #15 Step 5).
;;
;; First-party bundled extensions are just modules in the `extensions.*`
;; namespace. External extensions are loaded from explicit `--extension <path>`
;; entries plus the configured search roots. External entry modules return
;; either a function `(fn [api] ...)` or a table with `:register`.
;;
;; Mechanics live in three sibling modules so this file can stay an
;; orchestration script:
;;   - core.extensions.loader.manifest  — file/manifest reading + dep checks
;;   - core.extensions.loader.discover  — find candidate extensions on disk
;;   - core.extensions.loader.reload    — per-module fingerprint tracking

(local core-ext (require :core.extensions))
(local log (require :util.log))
(local manifest-mod (require :core.extensions.loader.manifest))
(local discover (require :core.extensions.loader.discover))
(local reload (require :core.extensions.loader.reload))

(local M {})

(local BUILTIN-EXTENSIONS
  [{:entry :extensions.default_prompt
    :manifest-module :extensions.default_prompt.manifest}
   {:entry :extensions.skills
    :manifest-module :extensions.skills.manifest}
   {:entry :extensions.builtin_tools
    :manifest-module :extensions.builtin_tools.manifest}
   {:entry :extensions.builtin_commands
    :manifest-module :extensions.builtin_commands.manifest}
   {:entry :extensions.agent_state
    :manifest-module :extensions.agent_state.manifest}
   {:entry :extensions.mem
    :manifest-module :extensions.mem.manifest}
   {:entry :extensions.tui
    :manifest-module :extensions.tui.manifest
    ;; Presenter/termbox extension: only meaningful in interactive mode.
    ;; Tool-only first-party extensions can omit this flag so they load for
    ;; both --print and interactive runs.
    :interactive-only? true}])

(local loaded {})

(fn load-builtin-spec! [spec reload?]
  (let [manifest (manifest-mod.read-manifest-module spec.manifest-module)
        name (or manifest.name spec.name spec.entry)
        changes (if reload?
                    (do
                      (core-ext.unregister-by-owner name)
                      (reload.clear-reload-modules! manifest [spec.entry]))
                    (reload.change-summary
                      (manifest-mod.reload-modules manifest [spec.entry])))]
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

(fn record-spec-status! [spec status extra]
  (let [rec {:manifest spec.manifest :status status :path spec.path}]
    (each [k v (pairs (or extra {}))] (tset rec k v))
    (core-ext.record-extension! spec.name rec)))

(fn record-spec-error! [spec err]
  ;; Tear down any partial batch before recording the failure so an errored
  ;; extension cannot leave half-active presenters/commands/handlers behind.
  (core-ext.unregister-by-owner spec.name)
  (record-spec-status! spec :error {:error (tostring err)})
  (log.warn (.. "extension " spec.name " failed: " (tostring err))))

(fn try-register-entry! [spec entry]
  "Validate the loaded entry shape and call its register fn under pcall.
   Returns (true nil) on success or (false err) on failure."
  (let [register (manifest-mod.entry-register entry)]
    (if (not (= (type register) :function))
        (values false "entry must return function or {:register fn}")
        (let [api (core-ext.make-api spec.name spec.manifest)
              (ok? reg-err) (pcall register api)]
          (if ok? (values true nil) (values false reg-err))))))

(fn load-external-spec! [spec]
  ;; Always tear down the previous contribution batch first. This makes
  ;; /reload and /reload-extension safe when an extension becomes disabled,
  ;; loses a dependency, or fails during registration.
  (core-ext.unregister-by-owner spec.name)
  (let [changes (reload.change-summary (manifest-mod.reload-modules spec.manifest []))]
    (when (reload.file-changed?! spec.entry)
      (set changes.checked (+ changes.checked 1))
      (set changes.changed (+ changes.changed 1))
      (table.insert changes.changed-modules spec.entry))
    (if (not (manifest-mod.enabled? spec))
        (do (record-spec-status! spec :disabled {})
            (values false :disabled changes))
        (let [missing (manifest-mod.missing-deps spec.manifest)]
          (if (> (length missing) 0)
              (do (record-spec-status! spec :missing-deps {:missing missing})
                  (log.warn (.. "extension " spec.name " disabled; missing "
                                (table.concat missing ", ")))
                  (values false :missing-deps changes))
              (do
                (reload.clear-reload-modules! spec.manifest [])
                (tset package.loaded spec.entry nil)
                (let [(entry load-err) (manifest-mod.load-file spec.entry)]
                  (if load-err
                      (do (record-spec-error! spec load-err)
                          (values false load-err changes))
                      (let [(reg-ok? reg-err) (try-register-entry! spec entry)]
                        (if reg-ok?
                            (do (record-spec-status! spec :loaded {})
                                (tset loaded spec.name spec)
                                (core-ext.emit {:type :extension-loaded
                                                :name spec.name})
                                (values true nil changes))
                            (do (record-spec-error! spec reg-err)
                                (values false reg-err changes))))))))))))

(fn M.load-external! [opts]
  (let [seen {}
        summaries []]
    (each [_ spec (ipairs (discover.discover-external (or opts.extension-paths [])))]
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
                                       :first-party? false})))))
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
