;; Runtime status inspector command and panel.

(local status (require :fen.extensions.status.commands.status))

(local M {})

(fn M.register [api]
  (status.register api)
  true)

M
