;; File/module fingerprint helpers for reload diagnostics, behind an injectable
;; fingerprint-provider backend seam.
;;
;; The public API dispatches through a backend resolved once at load
;; (fen.util.checksum.backend). The default backend
;; (fen.util.checksum.backends.default) fingerprints modules via
;; package.searchpath + io.open, exactly as before. That is invisible to
;; modules loaded through a custom package.searchers entry (a host's in-VM
;; compiler): module-fingerprint returns nil and the reload loader is forced to
;; reload-all every time, permanently disabling change detection. A host with
;; such a loader swaps the backend to supply a per-module version/etag,
;; restoring incremental reload.
;;
;; Tests and hosts swap the backend by pre-loading
;; `package.loaded["fen.util.checksum.backend"]` before requiring this module
;; (see fen.testing.stub-checksum!). This mirrors the fen.util.http /
;; fen.util.path / fen.util.clock seams: one mechanism, current behavior as the
;; default. See docs/architecture.md.

;; Resolved once at load, mirroring fen.util.path / fen.util.clock. On /reload
;; the module re-requires the backend, and tests swap it by pre-loading
;; package.loaded before requiring this module.
(local backend (require :fen.util.checksum.backend))

(local M {})

;; @doc fen.util.checksum.file-fingerprint
;; kind: function
;; signature: (file-fingerprint path) -> table|nil
;; summary: Compute a small non-cryptographic checksum/size fingerprint for a file via the injectable backend, used by reload-change diagnostics.
;; tags: util checksum reload
(fn M.file-fingerprint [path]
  (backend.file-fingerprint path))

;; @doc fen.util.checksum.module-path
;; kind: function
;; signature: (module-path modname) -> string|nil
;; summary: Resolve a module name to its active source file through the injectable backend so reload diagnostics can fingerprint it.
;; tags: util checksum modules
(fn M.module-path [modname]
  (backend.module-path modname))

;; @doc fen.util.checksum.module-fingerprint
;; kind: function
;; signature: (module-fingerprint modname) -> table|nil
;; summary: Return a module's fingerprint (version/etag) through the injectable backend; the default resolves and hashes the source file, returning nil when it has no discoverable source.
;; tags: util checksum modules reload
(fn M.module-fingerprint [modname]
  (backend.module-fingerprint modname))

M
