;; Per-module fingerprint tracking for extension reload.
;;
;; The state lives on `core.extensions.state.reload-fingerprints` so it
;; survives a /reload of this module. We compare a fresh checksum against the
;; cached one, update the cache, and report whether anything actually changed
;; — the loader uses this to tell the user "3 modules reloaded, 1 changed".
;;
;; `clear-reload-modules!` is the operational side: re-require the named
;; modules (subject to the manifest's reload-exclude list) and return a change
;; summary. Table-valued modules are updated in place so long-lived captures in
;; running presenters keep seeing fresh behavior.

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

(fn module-changed?! [modname]
  (changed-fingerprint?! (.. "module:" (tostring modname))
                         (checksum.module-fingerprint modname)))

(fn M.file-changed?! [file-path]
  (changed-fingerprint?! (.. "file:" (tostring file-path))
                         (checksum.file-fingerprint file-path)))

(fn M.change-summary [mods]
  "Probe each module for a fingerprint change, updating the cache. Returns a
   summary table the caller folds into the per-extension reload report."
  (let [summary {:checked 0 :changed 0 :changed-modules []}]
    (each [_ modname (ipairs (or mods []))]
      (set summary.checked (+ summary.checked 1))
      (when (module-changed?! modname)
        (set summary.changed (+ summary.changed 1))
        (table.insert summary.changed-modules modname)))
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

(fn M.clear-reload-modules! [manifest fallback]
  "Reload manifest.reload-modules (or `fallback`), skipping anything in
   reload-exclude. Returns the change summary so the caller can emit a single
   :extension-reloaded event with module-level detail."
  (let [mods (manifest-mod.reload-modules manifest fallback)
        excluded (manifest-mod.reload-exclude manifest)
        summary (M.change-summary mods)]
    (each [_ modname (ipairs mods)]
      (when (not (list-has? excluded modname))
        (let [(ok? err) (reload-module-in-place! modname)]
          (when (not ok?)
            (error (.. "reload " (tostring modname) ": " (tostring err)))))))
    summary))

M
