;; Kind dispatcher for `api.register :foo ...` plus the cross-cutting
;; sweeps and lookups that touch every kind (unregister-by-owner, list).
;;
;; Each per-kind file owns: register, unregister-by-owner, list, and any
;; verbs unique to that kind (run/dispatch/render). This module wires them
;; together through closures that resolve through each sub-module's table at
;; call time, so reloads of the per-kind files take effect immediately.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))
(local events (require :fen.core.extensions.events))
(local tool (require :fen.core.extensions.register.tool))
(local command (require :fen.core.extensions.register.command))
(local control (require :fen.core.extensions.register.control))
(local status (require :fen.core.extensions.register.status))
(local panel (require :fen.core.extensions.register.panel))
(local hook (require :fen.core.extensions.register.hook))
(local prompt (require :fen.core.extensions.register.prompt))
(local presenter (require :fen.core.extensions.register.presenter))

(local M {})

(fn handle-result [kind name owner unregister]
  {: kind : name : owner : unregister})

(fn M.register [kind spec owner]
  (if (= kind :tool) (tool.register spec owner handle-result)
      (= kind :command) (command.register spec owner handle-result)
      (= kind :control) (control.register spec owner handle-result)
      (= kind :status) (status.register spec owner handle-result)
      (= kind :panel) (panel.register spec owner handle-result)
      (= kind :hook) (hook.register spec owner handle-result)
      (= kind :presenter) (presenter.register spec owner handle-result)
      (= kind :system-prompt) (prompt.register spec owner handle-result)
      (error (.. "unknown register kind: " (tostring kind)))))

(fn M.unregister-by-owner [owner]
  "Drop every registration tagged with owner."
  (tool.unregister-by-owner owner)
  (command.unregister-by-owner owner)
  (control.unregister-by-owner owner)
  (status.unregister-by-owner owner)
  (panel.unregister-by-owner owner)
  (presenter.unregister-by-owner owner)
  (hook.unregister-by-owner owner)
  (prompt.unregister-by-owner owner)
  (events.unregister-by-owner owner)
  (tset state.extensions owner nil)
  nil)

(fn list-extensions []
  (let [out []]
    (each [name rec (pairs state.extensions)]
      (table.insert out {:name name :status rec.status :path rec.path
                         :first-party? rec.first-party?}))
    out))

(fn M.list [kind]
  (let [data (if (= kind :tools) (tool.list)
                 (= kind :commands) (command.list)
                 (= kind :controls) (control.list)
                 (= kind :status) (status.list)
                 (= kind :panels) (panel.list)
                 (= kind :presenters) (presenter.list)
                 (= kind :extensions) (list-extensions)
                 (= kind :event-handlers) (events.list)
                 (= kind :prompt-fragments) (prompt.list)
                 (error (.. "unknown list kind: " (tostring kind))))]
    (util.freeze data)))

;; Cross-module wrappers — call-time resolution through each sub-module
;; table so reloads pick up new behavior.
(fn M.merged-tools [base] (tool.merged base))
(fn M.run-before-tool [tool-name args ctx]
  (hook.run-before-tool tool-name args ctx))
(fn M.dispatch-command [line caller-state]
  (command.dispatch line caller-state))
(fn M.contribute [text-or-fn ?opts owner]
  (prompt.contribute text-or-fn ?opts owner handle-result))
(fn M.render-prompt [ctx] (prompt.render ctx))

(fn M.active-presenter [] (presenter.active-presenter))
(fn M.init-active-presenter [ctx] (presenter.init-active-presenter ctx))
(fn M.shutdown-active-presenter [ctx] (presenter.shutdown-active-presenter ctx))
(fn M.run-active-presenter [ctx] (presenter.run-active-presenter ctx))
(fn M.build-ui-slot [] (presenter.build-ui-slot))

M
