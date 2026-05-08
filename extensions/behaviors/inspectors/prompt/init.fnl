;; Prompt-fragment inspector command and panel.

(local prompt (require :fen.extensions.prompt.commands.prompt))

(local M {})

(fn M.register [api]
  (prompt.register api)
  true)

M
