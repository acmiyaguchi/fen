;; Conversation and session lifecycle commands.

(local session (require :fen.extensions.sessions.commands.session))

(local M {})

(fn M.register [api]
  (session.register api)
  true)

M
