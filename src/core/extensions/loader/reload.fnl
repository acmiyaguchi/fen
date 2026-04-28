;; Per-module fingerprint tracking for extension reload.
;;
;; The state lives on `core.extensions.state.reload-fingerprints` so it
;; survives a /reload of this module. We compare a fresh checksum against the
;; cached one, update the cache, and report whether anything actually changed
;; — the loader uses this to tell the user "3 modules reloaded, 1 changed".
;;
;; `clear-reload-modules!` is the operational side: drop the named modules
;; from `package.loaded` (subject to the manifest's reload-exclude list) and
;; return a change summary.

(local state (require :core.extensions.state))
(local checksum (require :util.checksum))
(local manifest-mod (require :core.extensions.loader.manifest))

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

(fn M.clear-reload-modules! [manifest fallback]
  "Drop manifest.reload-modules (or `fallback`) from package.loaded, skipping
   anything in reload-exclude. Returns the change summary so the caller can
   emit a single :extension-reloaded event with module-level detail."
  (let [mods (manifest-mod.reload-modules manifest fallback)
        excluded (manifest-mod.reload-exclude manifest)
        summary (M.change-summary mods)]
    (each [_ modname (ipairs mods)]
      (when (not (list-has? excluded modname))
        (tset package.loaded modname nil)))
    summary))

M
