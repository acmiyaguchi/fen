;; Fingerprint helpers behind an injectable backend seam; hosts with custom searchers swap it to restore incremental reload.

;; Backend resolved once at load; /reload re-requires it; tests pre-load package.loaded first.
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
