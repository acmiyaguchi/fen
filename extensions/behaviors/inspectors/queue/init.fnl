;; Queue inspector command and panel.

(local queue (require :fen.extensions.queue.commands.queue))

(local M {})

(fn M.register [api]
  (queue.register api)
  true)

M
