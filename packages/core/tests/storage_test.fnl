;; Tests for the fen.core.storage config-document seam and its injection points.
;;
;; Covers three things the #476 seam promises:
;;   1. An injected storage backend round-trips settings and serves models.json
;;      with no filesystem access at all.
;;   2. The default XDG-file backend keeps its temp-file + rename atomic write
;;      and nil-on-missing read behavior unchanged.
;;   3. models.json API-key env-var references resolve through the injectable
;;      fen.util.path VFS getenv, not os.getenv.

(local h (require :fen.testing))

(describe "core.storage default backend"
  (fn []
    (var tmp nil)
    (var storage nil)

    (before_each
      (fn []
        ;; Ensure the default backend is active even if an earlier test swapped it.
        (h.restore-storage!)
        (set tmp (h.make-tmpdir))
        (set storage (h.reload-module :fen.core.storage))))

    (after_each
      (fn []
        (h.restore-storage!)
        (when tmp (h.rmtree tmp))))

    (it "returns nil for a missing document"
      (fn []
        (assert.is_nil (storage.read (.. tmp "/nope.json")))))

    (it "writes atomically (temp-file + rename) and reads the bytes back"
      (fn []
        (let [p (.. tmp "/sub/dir/doc.json")]
          (storage.write! p "hello-bytes")
          ;; No leftover temp file: the rename replaced it atomically.
          (assert.is_nil (h.read-file (.. p ".tmp")))
          ;; Readable both through the seam and directly on disk.
          (assert.are.equal "hello-bytes" (storage.read p))
          (assert.are.equal "hello-bytes" (h.read-file p)))))

    (it "creates missing parent directories on write"
      (fn []
        (let [p (.. tmp "/a/b/c/doc.json")]
          (storage.write! p "{}")
          (assert.are.equal "{}" (h.read-file p)))))))

(describe "core.storage injected backend (no filesystem)"
  (fn []
    (local extensions (require :fen.core.extensions.test_api))
    (var store nil)
    (var settings nil)
    (var models-mod nil)

    (before_each
      (fn []
        (extensions.reset!)
        (set store {})
        ;; In-memory config store keyed by resolved path — no io.open/rename.
        (h.stub-storage!
          {:read (fn [p] (. store p))
           :write! (fn [p content] (tset store p content))})
        ;; Injected VFS env: supplies XDG/HOME for path resolution and the
        ;; API-key env var, so nothing reaches os.getenv or the OS filesystem.
        (h.stub-path-vfs!
          {:getenv (fn [name]
                     (if (= name :XDG_CONFIG_HOME) "/cfg"
                         (= name :HOME) "/home"
                         (= name :MY_MODEL_KEY) "secret-via-path-getenv"
                         nil))})
        (set settings (h.reload-module :fen.core.settings))
        (set models-mod (h.reload-module :fen.core.llm.models))))

    (after_each
      (fn []
        (h.restore-path-vfs!)
        (h.restore-storage!)
        (extensions.reset!)))

    (it "round-trips settings entirely in the injected backend"
      (fn []
        (settings.set-defaults! :openai-codex :gpt-5.5)
        (let [out (settings.load)]
          (assert.are.equal :openai-codex out.default-provider)
          (assert.are.equal :gpt-5.5 out.default-model))
        ;; The bytes landed in the in-memory store, not on disk.
        (assert.is_string (. store (settings.config-path)))
        ;; No temp document was ever created in the store.
        (assert.is_nil (. store (.. (settings.config-path) ".tmp")))))

    (it "preserves unknown top-level keys through the injected backend"
      (fn []
        (tset store (settings.config-path)
              "{\"theme\":\"dark\",\"defaultProvider\":\"openai\"}")
        (settings.set-defaults! :anthropic :claude-sonnet-4-6)
        (let [raw (. store (settings.config-path))]
          (assert.is_truthy (string.find raw "\"theme\":\"dark\"" 1 true)))
        (let [out (settings.load)]
          (assert.are.equal :anthropic out.default-provider))))

    (it "serves models.json from the injected backend"
      (fn []
        (tset store (models-mod.config-path)
              (.. "{\"providers\": {\"ollama\": {"
                  "\"api\": \"openai-completions\","
                  "\"models\": [{\"id\": \"llama3.1:8b\"}]"
                  "}}}"))
        (let [providers (models-mod.load)]
          (assert.is_table (. providers :ollama)))
        (let [p (models-mod.get-provider :ollama)]
          (assert.are.equal "openai-completions" p.api)
          (assert.are.equal "llama3.1:8b" (. p.models 1 :id)))))

    (it "resolves a models.json apiKey env var through the injected path getenv"
      (fn []
        (tset store (models-mod.config-path)
              (.. "{\"providers\": {\"x\": {"
                  "\"api\": \"openai-completions\","
                  "\"apiKey\": \"MY_MODEL_KEY\""
                  "}}}"))
        (let [p (models-mod.get-provider :x)]
          ;; Value came from the injected VFS getenv, not os.getenv.
          (assert.are.equal "secret-via-path-getenv" p.api-key)
          (assert.are.equal "MY_MODEL_KEY" p.api-key-var))))))
