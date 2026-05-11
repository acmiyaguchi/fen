;; Essential first-party slash commands.

(local help (require :fen.extensions.essentials.commands.help))
(local model (require :fen.extensions.essentials.commands.model))
(local thinking (require :fen.extensions.essentials.commands.thinking))

(local M {})

(fn M.register [api]
  (help.register api)
  (model.register api)
  (thinking.register api)
  true)

M
