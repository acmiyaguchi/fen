;; Opt-in development statistical profiler.

(local commands (require :fen.extensions.profiler.commands))

(local M {})

(fn M.register [api]
  (commands.register api)
  true)

M
