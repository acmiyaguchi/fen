;; Extension discovery: build the deduped extension spec list.
;;
;; Discovery has two parts. Enumerating the raw spec list from the environment
;; (explicit paths, project/user/first-party roots, embedded first-party
;; manifests) is routed through an injectable backend
;; (fen.core.extensions.loader.discover.backend); the default backend
;; (fen.core.extensions.loader.discover.backends.posix) keeps the exact current
;; POSIX enumeration — POSIX `find`, cwd ancestry, and env roots. This module
;; owns only the backend-independent policy: priority ordering (implied by the
;; order the backend returns specs) and name dedupe with shadowed-version
;; annotations. The loader consumes the deduped spec list and decides what to
;; actually load; the manifest data shape and downstream loader behavior do not
;; depend on which backend enumerated the specs.
;;
;; An embedded host with no `find`, no cwd ancestry, and no filesystem supplies
;; its own enumeration backend (returning the discovered-manifest list
;; directly) before first require, so it need not swap this module or the
;; loader. This mirrors the fen.util.path / fen.util.process seams: one
;; mechanism (the injectable backend) with the current behavior as the default.
;; See docs/architecture.md.

;; Resolved once at load, mirroring fen.util.path. On /reload this module
;; re-requires the backend (both are core-reloadable), and tests swap it by
;; pre-loading package.loaded before requiring this module
;; (fen.testing.stub-discover-enumeration!).
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

;; @doc fen.core.extensions.loader.discover.discover
;; kind: function
;; signature: (discover explicit-paths ?yield-fn) -> [ExtensionSpec]
;; summary: Build the deduped extension spec list in load-priority order by deduping the injectable backend's enumeration (explicit, first-party flat overlays, project, user, then embedded first-party).
;; tags: extensions loader discovery
(fn M.discover [explicit-paths ?yield-fn]
  "Return the merged spec list in load priority: explicit overrides trusted
   first-party flat overlays, which override project, user, and embedded
   first-party specs. Within each source, the first match found wins. The raw
   spec list comes from the injectable enumeration backend; this module applies
   the shared name dedupe and shadowed-version annotations."
  (dedupe-by-name! (backend.enumerate explicit-paths ?yield-fn)))

M
