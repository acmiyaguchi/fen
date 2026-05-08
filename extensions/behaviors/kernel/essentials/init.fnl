;; Essential first-party slash commands.

(local help (require :fen.extensions.essentials.commands.help))
(local model (require :fen.extensions.essentials.commands.model))

(local M {})

(fn M.register [api]
  (help.register api)
  (model.register api)
  true)

M
