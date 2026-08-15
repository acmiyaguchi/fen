;; Config-document storage behind an injectable backend seam.

;; Resolved once at load; tests/hosts swap by pre-loading
;; package.loaded["fen.core.storage.backend"] before requiring this module.
(local backend (require :fen.core.storage.backend))

(local M {})

(fn M.read [path]
  "Return the document's raw string contents, or nil when it does not exist.
   The default backend reads via io.open; a host swaps in its own persistence."
  (backend.read path))

(fn M.write! [path content]
  "Atomically replace the document at `path` with `content`. The default
   backend ensures the parent directory exists then writes a temp file and
   renames it into place; a host swaps in its own persistence."
  (backend.write! path content))

M
