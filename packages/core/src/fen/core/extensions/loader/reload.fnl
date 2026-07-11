;; Per-module fingerprint tracking for extension reload.
;;
;; The state lives on `core.extensions.state.reload-fingerprints` so it
;; survives a /reload of this module. We compare a fresh checksum against the
;; cached one, update the cache, and report whether anything actually changed
;; — the loader uses this to tell the user "3 modules reloaded, 1 changed".
;;
;; `clear-reload-modules!` is the operational side: re-require modules from
;; the first changed name onward (subject to the manifest's reload-exclude
;; list) and return a change summary. Table-valued modules are updated in place
;; so long-lived captures in running presenters keep seeing fresh behavior.

(local state (require :fen.core.extensions.state))
(local checksum (require :fen.util.checksum))
(local manifest-mod (require :fen.core.extensions.loader.manifest))

(local M {})

(fn list-has? [xs x]
  (var found false)
  (each [_ v (ipairs (or xs []))]
    (when (= v x) (set found true)))
  found)

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

(fn module-change [modname]
  (let [fp (checksum.module-fingerprint modname)]
    (values
      (changed-fingerprint?! (.. "module:" (tostring modname)) fp)
      (not= fp nil))))

;; @doc fen.core.extensions.loader.reload.file-changed?!
;; kind: function
;; signature: (file-changed?! file-path) -> boolean
;; summary: Update and compare the cached fingerprint for a path-shaped extension file, returning true only after a prior baseline changed.
;; tags: extensions loader reload fingerprint
(fn M.file-changed?! [file-path]
  (changed-fingerprint?! (.. "file:" (tostring file-path))
                         (checksum.file-fingerprint file-path)))

;; @doc fen.core.extensions.loader.reload.change-summary
;; kind: function
;; signature: (change-summary mods) -> ReloadChangeSummary
;; summary: Probe module fingerprints, update the reload cache, and return checked/changed counts plus changed module names.
;; tags: extensions loader reload fingerprint
(fn M.change-summary [mods]
  "Probe each module for a fingerprint change, updating the cache. Returns a
   summary table the caller folds into the per-extension reload report."
  (let [summary {:checked 0 :changed 0 :changed-modules []
                 :unresolved-modules []}]
    (each [_ modname (ipairs (or mods []))]
      (set summary.checked (+ summary.checked 1))
      (let [(changed? resolved?) (module-change modname)]
        (when changed?
          (set summary.changed (+ summary.changed 1))
          (table.insert summary.changed-modules modname))
        ;; A module without a source fingerprint cannot use the unchanged fast
        ;; path; package.preload extensions still need their historical reload.
        (when (not resolved?)
          (table.insert summary.unresolved-modules modname))))
    summary))

(fn reload-module-in-place! [modname]
  "Re-run modname. If both old and new exports are tables, mutate the old table
   in place so existing `(local m (require ...))` captures see new functions."
  (let [old (. package.loaded modname)]
    (tset package.loaded modname nil)
    (let [(ok? new) (pcall require modname)]
      (if (not ok?)
          (do (tset package.loaded modname old)
              (values false new))
          (do
            (when (and (= (type old) :table) (= (type new) :table))
              (each [k _ (pairs old)] (tset old k nil))
              (each [k v (pairs new)] (tset old k v))
              (tset package.loaded modname old))
            (values true nil))))))

;; @doc fen.core.extensions.loader.reload.clear-reload-modules!
;; kind: function
;; signature: (clear-reload-modules! manifest fallback) -> ReloadChangeSummary
;; summary: Re-require changed manifest reload modules and their downstream consumers in place, respecting reload-exclude, and return one summary for user-facing reload diagnostics.
;; tags: extensions loader reload
(fn M.clear-reload-modules! [manifest fallback]
  "Reload manifest.reload-modules (or `fallback`) from the first changed
   module onward, skipping reload-exclude. Returns the change summary so the
   caller can emit one :extension-reloaded event with module-level detail."
  (let [mods (manifest-mod.reload-modules manifest fallback)
        excluded (manifest-mod.reload-exclude manifest)
        summary (M.change-summary mods)
        changed {}]
    (each [_ modname (ipairs summary.changed-modules)]
      (tset changed modname true))
    (each [_ modname (ipairs (or summary.unresolved-modules []))]
      (tset changed modname true))
    ;; Manifests list dependencies before their consumers. Start at the first
    ;; changed module so unchanged dependencies stay cached while downstream
    ;; captures and the entry module are refreshed in declaration order.
    (var reload? false)
    (each [_ modname (ipairs mods)]
      (when (. changed modname) (set reload? true))
      (when (and reload? (not (list-has? excluded modname)))
        (let [(ok? err) (reload-module-in-place! modname)]
          (when (not ok?)
            (error (.. "reload " (tostring modname) ": " (tostring err)))))))
    summary))

;; Persistent-identity modules that must never reload in place: their tables
;; hold live state whose identity the rest of the process depends on (see
;; docs/development.md "What reloads, what doesn't"). fen.extensions.* state
;; modules are excluded by prefix below, so they are not listed here.
(local NON-RELOADABLE
  {:fen.main true
   :fen.core.extensions.state true})

(fn core-reloadable? [modname]
  (and (= (type modname) :string)
       (not= nil (string.find modname "^fen%."))
       ;; extension modules reload through their manifest's reload-modules
       (= nil (string.find modname "^fen%.extensions%."))
       (not (. NON-RELOADABLE modname))))

;; @doc fen.core.extensions.loader.reload.core-modules
;; kind: function
;; signature: (core-modules) -> [module-name]
;; summary: Currently-loaded core/util/CLI modules eligible for in-place reload, derived from package.loaded; extension modules and persistent-identity modules are excluded.
;; tags: extensions loader reload
(fn M.core-modules []
  "Derive the reloadable core set from package.loaded instead of a hand-kept
   list: every loaded `fen.*` module except `fen.extensions.*` and the
   persistent-identity modules, sorted for deterministic reload order."
  (let [out []]
    (each [modname (pairs package.loaded)]
      (when (core-reloadable? modname)
        (table.insert out modname)))
    (table.sort out)
    out))

;; @doc fen.core.extensions.loader.reload.snapshot-core!
;; kind: function
;; signature: (snapshot-core!) -> nil
;; summary: Baseline fingerprints for the currently-loaded core modules so the first /reload after startup reports only real changes.
;; tags: extensions loader reload fingerprint
(fn M.snapshot-core! []
  (each [_ m (ipairs (M.core-modules))]
    (module-change m)))

;; @doc fen.core.extensions.loader.reload.reload-core!
;; kind: function
;; signature: (reload-core! ?yield) -> (ok-count [failure] ReloadCoreSummary)
;; summary: Reload every currently-loaded core module in place, yielding periodically so the TUI can repaint, and return counts plus per-module failure strings.
;; tags: extensions loader reload
(fn M.reload-core! [?yield]
  (var ok-count 0)
  (var changed-count 0)
  (let [failures []
        changed-modules []]
    (each [_ m (ipairs (M.core-modules))]
      (let [(changed? _resolved?) (module-change m)
            (ok? err) (reload-module-in-place! m)]
        (if ok?
            (do
              (set ok-count (+ ok-count 1))
              (when changed?
                (set changed-count (+ changed-count 1))
                (table.insert changed-modules m)))
            (table.insert failures (.. m ": " (tostring err))))
        (when (and ?yield (= (% ok-count 8) 0))
          (?yield {:phase :core :module m}))))
    (when (and ?yield (not= (% ok-count 8) 0))
      (?yield {:phase :core :module :done}))
    (values ok-count failures
            {:reloaded ok-count
             :changed changed-count
             :changed-modules changed-modules
             :failed (length failures)})))

M
