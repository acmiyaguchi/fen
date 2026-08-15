;; Backend-independent discovery policy: name dedupe + shadowed-version annotations
;; over the injectable enumeration backend's priority-ordered spec list.

;; Resolved once at load; tests swap the backend via package.loaded before requiring this.
(local backend (require :fen.core.extensions.loader.discover.backend))

(local M {})

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

(fn M.discover [explicit-paths ?yield-fn]
  "Return the merged spec list in load priority: explicit overrides trusted
   first-party flat overlays, which override project, user, and embedded
   first-party specs. Within each source, the first match found wins. The raw
   spec list comes from the injectable enumeration backend; this module applies
   the shared name dedupe and shadowed-version annotations."
  (dedupe-by-name! (backend.enumerate explicit-paths ?yield-fn)))

M
