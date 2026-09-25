;; Legacy registry-level test facade. Keep this out of production core.
(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local register (require :fen.core.extensions.register))
(local commands (require :fen.core.extensions.register.command))
(local tools (require :fen.core.extensions.register.tool))
(local hooks (require :fen.core.extensions.register.hook))
(local input (require :fen.core.extensions.input))
(local prompts (require :fen.core.extensions.register.prompt))
(local presenters (require :fen.core.extensions.register.presenter))
(local introspection (require :fen.core.extensions.register.introspect))
(local providers (require :fen.core.extensions.register.provider))
(local auth (require :fen.core.extensions.register.auth_backend))
(local sessions (require :fen.core.extensions.register.session_backend))

(fn handle-result [kind name owner unregister]
  {: kind : name : owner : unregister})

{:reset! test-api.reset!
 :emit events.emit
 :on events.on
 :register register.register
 :unregister-by-owner register.unregister-by-owner
 :list register.list
 :dispatch-command commands.dispatch
 :merged-tools tools.merged
 :run-before-tool hooks.run-before-tool
 :handle-input input.handle
 :prompt (fn [text-or-fn ?opts owner]
           (prompts.contribute text-or-fn ?opts owner handle-result))
 :render-prompt prompts.render
 :active-presenter presenters.active-presenter
 :init-active-presenter presenters.init-active-presenter
 :run-active-presenter presenters.run-active-presenter
 :shutdown-active-presenter presenters.shutdown-active-presenter
 :collect-introspection introspection.collect
 :find-provider providers.find
 :find-auth-backend auth.find
 :find-session-backend sessions.find
 :set-active-session-backend! sessions.set-active!
 :active-session-backend sessions.active
 :set-session-info! sessions.set-info!
 :session-info sessions.info}
