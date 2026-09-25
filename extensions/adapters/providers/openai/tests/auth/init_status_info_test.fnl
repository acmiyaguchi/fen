;; Tests for the auth-backend `:status-info` callback registered by
;; extensions/adapters/providers/openai/init.fnl. We exercise it directly
;; via auth-reg.find so the test is independent of /status
;; rendering.
;;
;; Lua has no setenv, so we substitute os.getenv with a stub for the
;; duration of each test. Restore on teardown.

(local auth-reg (require :fen.core.extensions.register.auth_backend))
(local ext-api (require :fen.core.extensions.test_api))

(fn load-codex-backend []
  (ext-api.reset!)
  (tset package.loaded :fen.extensions.provider_openai nil)
  (let [mod (require :fen.extensions.provider_openai)
        api (ext-api.make-runtime-api :provider_openai)]
    (mod.register api)))

(fn with-stubbed-getenv [env-table body]
  (let [original os.getenv]
    (set os.getenv (fn [k] (. env-table k)))
    (let [(ok? err) (pcall body)]
      (set os.getenv original)
      (when (not ok?) (error err)))))

(describe "openai-codex auth-backend :status-info"
  (fn []
    (it "exposes only the fen auth path under no overrides"
      (fn []
        (with-stubbed-getenv {:HOME "/h"}
          (fn []
            (load-codex-backend)
            (let [backend (auth-reg.find :openai-codex)
                  rows (backend.status-info)]
              (assert.are.equal 1 (length rows))
              (assert.are.equal "auth.json path" (. rows 1 :label))
              (assert.are.equal "/h/.config/fen/auth.json"
                                (. rows 1 :value)))))))

    (it "surfaces $FEN_AUTH_DIR as the write override"
      (fn []
        (with-stubbed-getenv {:HOME "/h" :FEN_AUTH_DIR "/tmp/fen-only"}
          (fn []
            (load-codex-backend)
            (let [backend (auth-reg.find :openai-codex)
                  rows (backend.status-info)]
              (assert.are.equal 2 (length rows))
              (assert.are.equal "auth.json path" (. rows 1 :label))
              (assert.are.equal "/tmp/fen-only/auth.json"
                                (. rows 1 :value))
              (assert.are.equal "path override" (. rows 2 :label))
              (assert.are.equal "$FEN_AUTH_DIR" (. rows 2 :value)))))))

    (it "ignores $PI_CODING_AGENT_DIR"
      (fn []
        (with-stubbed-getenv {:HOME "/h" :PI_CODING_AGENT_DIR "/tmp/pi-shared"}
          (fn []
            (load-codex-backend)
            (let [backend (auth-reg.find :openai-codex)
                  rows (backend.status-info)]
              (assert.are.equal 1 (length rows))
              (assert.are.equal "/h/.config/fen/auth.json"
                                (. rows 1 :value)))))))

    (it "FEN_AUTH_DIR sets the auth path while PI_CODING_AGENT_DIR stays ignored"
      (fn []
        (with-stubbed-getenv {:HOME "/h"
                              :FEN_AUTH_DIR "/tmp/fen-only"
                              :PI_CODING_AGENT_DIR "/tmp/pi-shared"}
          (fn []
            (load-codex-backend)
            (let [backend (auth-reg.find :openai-codex)
                  rows (backend.status-info)]
              (assert.are.equal 2 (length rows))
              (assert.are.equal "/tmp/fen-only/auth.json"
                                (. rows 1 :value))
              (assert.are.equal "$FEN_AUTH_DIR" (. rows 2 :value)))))))))
