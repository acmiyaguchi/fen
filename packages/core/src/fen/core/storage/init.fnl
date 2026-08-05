;; Config-document storage helpers behind an injectable backend seam.
;;
;; Config persistence (settings.json read/write, models.json read) used to be
;; raw POSIX in each caller: io.open to slurp, and mkdir -p + temp-file +
;; os.rename/os.remove for the atomic settings write. This module owns that one
;; storage surface — reading and atomically writing a named config document by
;; path — and dispatches it through a backend resolved once at load
;; (fen.core.storage.backend). The default backend
;; (fen.core.storage.backends.default) keeps the exact XDG-file behavior,
;; including the temp-file + rename atomic write; an embedded host that backs
;; config with its own persistence swaps the backend.
;;
;; Tests and hosts swap the backend by pre-loading
;; `package.loaded["fen.core.storage.backend"]` before requiring this module
;; (see fen.testing.stub-storage!). This mirrors the fen.util.path /
;; fen.util.http / fen.core.extensions.loader.discover seams: one mechanism, the
;; injectable backend, with the current behavior as the default. Path grammar
;; and the XDG location of the documents stay with the callers (via
;; fen.util.path); this module only reads and writes bytes at a resolved path.
;; See docs/architecture.md.

;; Resolved once at load, mirroring fen.util.path / fen.util.checksum. On
;; /reload the module re-requires the backend, and tests swap it by pre-loading
;; package.loaded before requiring this module.
(local backend (require :fen.core.storage.backend))

(local M {})

;; @doc fen.core.storage.read
;; kind: function
;; signature: (read path) -> string|nil
;; summary: Read a config document's raw contents through the injectable storage backend, returning nil when it is absent.
;; tags: storage config io seam
(fn M.read [path]
  "Return the document's raw string contents, or nil when it does not exist.
   The default backend reads via io.open; a host swaps in its own persistence."
  (backend.read path))

;; @doc fen.core.storage.write!
;; kind: function
;; signature: (write! path content) -> nil
;; summary: Atomically write a config document's contents through the injectable storage backend (default: mkdir -p + temp-file + rename).
;; tags: storage config io seam write
(fn M.write! [path content]
  "Atomically replace the document at `path` with `content`. The default
   backend ensures the parent directory exists then writes a temp file and
   renames it into place; a host swaps in its own persistence."
  (backend.write! path content))

M
