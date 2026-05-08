;; Extension inspector command, reload command, and panel.

(local extension (require :fen.extensions.extensions_inspector.commands.extension))

(local M {})

(fn M.register [api]
  (extension.register api)
  true)

M
