;; Built-in slash commands.
;;
;; Loading this module is side-effect-only: it clears the prior built-in
;; command registrations and asks the smaller command modules to register
;; their handlers against the shared extension API.
;;
;; Handlers receive `(args state)` where `args` is the substring after the
;; command name and `state` is the run-interactive state record.
;;
;; This module does not import the TUI. Presenter effects are requested via
;; bus events (`:reset-conversation`, `:reinit-presenter`, `:redraw`,
;; `:set-status-info`); the active presenter may subscribe to them.

(local extensions (require :fen.core.extensions))

(local status (require :fen.extensions.builtin_commands.commands.status))
(local model (require :fen.extensions.builtin_commands.commands.model))
(local session (require :fen.extensions.builtin_commands.commands.session))
(local extension (require :fen.extensions.builtin_commands.commands.extension))
(local prompt-cmd (require :fen.extensions.builtin_commands.commands.prompt))
(local queue (require :fen.extensions.builtin_commands.commands.queue))
(local help (require :fen.extensions.builtin_commands.commands.help))

(local M {})

;; On reload this module re-registers everything; drop the prior batch first
;; so a renamed/removed command doesn't leak.
(extensions.unregister-by-owner :builtin_commands)
(local api (extensions.make-api :builtin_commands))

(status.register api)
(model.register api)
(session.register api)
(extension.register api)
(prompt-cmd.register api)

;; /expand, /markdown, /thinking live in extensions.tui. They mutate TUI state
;; directly and register from inside the TUI extension. /help still documents
;; them because they are first-party interactive commands when the TUI is active.

(queue.register api)
(help.register api)

M
