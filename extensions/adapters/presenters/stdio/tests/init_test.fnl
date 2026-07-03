(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local register-registry (require :fen.core.extensions.register))
(local command-registry (require :fen.core.extensions.register.command))
(local tool-registry (require :fen.core.extensions.register.tool))
(local hook-registry (require :fen.core.extensions.register.hook))
(local prompt-registry (require :fen.core.extensions.register.prompt))
(local presenter-registry (require :fen.core.extensions.register.presenter))
(local provider-registry (require :fen.core.extensions.register.provider))
(local auth-backend-registry (require :fen.core.extensions.register.auth_backend))
(local session-backend-registry (require :fen.core.extensions.register.session_backend))
(fn handle-result [kind name owner unregister]
  {: kind : name : owner : unregister})
(local extensions
  {:reset! test-api.reset!
   :emit events.emit
   :on events.on
   :register register-registry.register
   :unregister-by-owner register-registry.unregister-by-owner
   :list register-registry.list
   :dispatch-command command-registry.dispatch
   :merged-tools tool-registry.merged
   :run-before-tool hook-registry.run-before-tool
   :prompt (fn [text-or-fn ?opts owner]
             (prompt-registry.contribute text-or-fn ?opts owner handle-result))
   :render-prompt prompt-registry.render
   :active-presenter presenter-registry.active-presenter
   :init-active-presenter presenter-registry.init-active-presenter
   :run-active-presenter presenter-registry.run-active-presenter
   :shutdown-active-presenter presenter-registry.shutdown-active-presenter
   :find-provider provider-registry.find
   :find-auth-backend auth-backend-registry.find
   :find-session-backend session-backend-registry.find
   :set-active-session-backend! session-backend-registry.set-active!
   :active-session-backend session-backend-registry.active
   :set-session-info! session-backend-registry.set-info!
   :session-info session-backend-registry.info})
(local ext-api (require :fen.core.extensions.test_api))

(describe "stdio presenter"
  (before_each
    (fn []
      (extensions.reset!)
      (tset package.loaded :fen.extensions.stdio nil)))

  (after_each
    (fn []
      (extensions.reset!)
      (tset package.loaded :fen.extensions.stdio nil)))

  (it "registers an active presenter without loading termbox2"
    (fn []
      (let [stdio (require :fen.extensions.stdio)
            api (ext-api.make-runtime-api :stdio)]
        (stdio.register api)
        (let [presenter (extensions.active-presenter)]
        (assert.is_table stdio)
        (assert.is_table presenter)
        (assert.are.equal :stdio presenter.name)
        (assert.is_true presenter.active?)
        (assert.is_function presenter.run)
        (assert.is_table presenter.ui)
        (assert.is_function presenter.ui.notify)
        (assert.is_function presenter.ui.prompt)
          (assert.is_function presenter.ui.select))))))
