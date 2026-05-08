;; Tests for the auth-backend `:status-info` callback registered by
;; extensions/provider-openai-codex/init.fnl. We exercise it directly
;; via extensions.find-auth-backend so the test is independent of /status
;; rendering.
;;
;; Lua has no setenv, so we substitute os.getenv with a stub for the
;; duration of each test. Restore on teardown.

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
   :list-providers-by-api provider-registry.list-by-api
   :find-auth-backend auth-backend-registry.find
   :find-session-backend session-backend-registry.find
   :set-active-session-backend! session-backend-registry.set-active!
   :active-session-backend session-backend-registry.active
   :set-session-info! session-backend-registry.set-info!
   :session-info session-backend-registry.info})
(local ext-api (require :fen.core.extensions.test_api))

;; Force the codex extension to (re-)load against a fresh registry so its
;; api.register :auth-backend runs and the :status-info field lands.
(fn load-codex-backend []
  (extensions.reset!)
  (tset package.loaded :fen.extensions.provider_openai_codex nil)
  (let [mod (require :fen.extensions.provider_openai_codex)
        api (ext-api.make-runtime-api :provider_openai_codex)]
    (mod.register api)))

(fn with-stubbed-getenv [env-table body]
  (let [original os.getenv]
    (set os.getenv (fn [k] (. env-table k)))
    (let [(ok? err) (pcall body)]
      (set os.getenv original)
      (when (not ok?) (error err)))))

(describe "openai-codex auth-backend :status-info"
  (fn []
    (it "exposes the fen write path and pi read fallback under no overrides"
      (fn []
        (with-stubbed-getenv {:HOME "/h"}
          (fn []
            (load-codex-backend)
            (let [backend (extensions.find-auth-backend :openai-codex)
                  rows (backend.status-info)]
              (assert.are.equal 2 (length rows))
              (assert.are.equal "auth.json write" (. rows 1 :label))
              (assert.are.equal "/h/.config/fen/auth.json"
                                (. rows 1 :value))
              (assert.are.equal "read fallback" (. rows 2 :label))
              (assert.are.equal "/h/.pi/agent/auth.json"
                                (. rows 2 :value)))))))

    (it "surfaces $FEN_AUTH_DIR as the write override"
      (fn []
        (with-stubbed-getenv {:HOME "/h" :FEN_AUTH_DIR "/tmp/fen-only"}
          (fn []
            (load-codex-backend)
            (let [backend (extensions.find-auth-backend :openai-codex)
                  rows (backend.status-info)]
              (assert.are.equal 3 (length rows))
              (assert.are.equal "auth.json write" (. rows 1 :label))
              (assert.are.equal "/tmp/fen-only/auth.json"
                                (. rows 1 :value))
              (assert.are.equal "write override" (. rows 2 :label))
              (assert.are.equal "$FEN_AUTH_DIR" (. rows 2 :value))
              (assert.are.equal "/h/.pi/agent/auth.json" (. rows 3 :value)))))))

    (it "surfaces $PI_CODING_AGENT_DIR as a read-only fallback"
      (fn []
        (with-stubbed-getenv {:HOME "/h" :PI_CODING_AGENT_DIR "/tmp/pi-shared"}
          (fn []
            (load-codex-backend)
            (let [backend (extensions.find-auth-backend :openai-codex)
                  rows (backend.status-info)]
              (assert.are.equal 3 (length rows))
              (assert.are.equal "/h/.config/fen/auth.json"
                                (. rows 1 :value))
              (assert.are.equal "read fallback" (. rows 2 :label))
              (assert.are.equal "/tmp/pi-shared/auth.json" (. rows 2 :value))
              (assert.are.equal "/h/.pi/agent/auth.json" (. rows 3 :value)))))))

    (it "FEN_AUTH_DIR sets write path while PI_CODING_AGENT_DIR remains fallback"
      (fn []
        (with-stubbed-getenv {:HOME "/h"
                              :FEN_AUTH_DIR "/tmp/fen-only"
                              :PI_CODING_AGENT_DIR "/tmp/pi-shared"}
          (fn []
            (load-codex-backend)
            (let [backend (extensions.find-auth-backend :openai-codex)
                  rows (backend.status-info)]
              (assert.are.equal "/tmp/fen-only/auth.json"
                                (. rows 1 :value))
              (assert.are.equal "$FEN_AUTH_DIR" (. rows 2 :value))
              (assert.are.equal "/tmp/pi-shared/auth.json" (. rows 3 :value))
              (assert.are.equal "/h/.pi/agent/auth.json" (. rows 4 :value)))))))))
