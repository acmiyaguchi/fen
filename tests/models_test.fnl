;; Tests for core.llm.models — models.json loader.
;;
;; Strategy: override XDG_CONFIG_HOME via an os.getenv monkey-patch so
;; config-dir resolves under a tmpdir we control. Each test re-requires
;; the module to drop the load-cache.

(local h (require :test_helpers))

(local make-tmpdir h.make-tmpdir)
(local rmtree h.rmtree)
(local write-file h.write-file)

(describe "core.llm.models.load"
  (fn []
    (var tmp nil)
    (var models-mod nil)

    (before_each
      (fn []
        (set tmp (make-tmpdir))
        (h.stub-getenv!
          (fn [name orig]
            (if (= name :XDG_CONFIG_HOME) tmp
                (= name :HOME) tmp
                (orig name))))
        (set models-mod (h.reload-module :core.llm.models))))

    (after_each
      (fn []
        (h.restore-getenv!)
        (when tmp (rmtree tmp))))

    (it "returns an empty map when models.json does not exist"
      (fn []
        (let [out (models-mod.load)]
          (assert.is_table out)
          (assert.is_nil (next out)))))

    (it "returns an empty map for malformed JSON without crashing"
      (fn []
        (write-file (.. tmp "/fen/models.json")
                    "{\"providers\": { not valid json")
        (let [out (models-mod.load)]
          (assert.is_table out)
          (assert.is_nil (next out)))))

    (it "returns an empty map when the file lacks a top-level providers object"
      (fn []
        (write-file (.. tmp "/fen/models.json")
                    "{\"foo\": 1}")
        (let [out (models-mod.load)]
          (assert.is_table out)
          (assert.is_nil (next out)))))))

(describe "core.llm.models.get-provider"
  (fn []
    (var tmp nil)
    (var models-mod nil)
    (var fake-env {})

    (before_each
      (fn []
        (set tmp (make-tmpdir))
        (set fake-env {})
        (h.stub-getenv!
          (fn [name orig]
            (if (= name :XDG_CONFIG_HOME) tmp
                (= name :HOME) tmp
                (string.match (tostring name) "^[A-Z][A-Z0-9_]*$") (. fake-env name)
                (orig name))))
        (set models-mod (h.reload-module :core.llm.models))))

    (after_each
      (fn []
        (h.restore-getenv!)
        (when tmp (rmtree tmp))))

    (it "returns nil when the named provider isn't configured"
      (fn []
        (write-file (.. tmp "/fen/models.json")
                    "{\"providers\": {}}")
        (assert.is_nil (models-mod.get-provider :ollama))))

    (it "normalizes a valid Ollama config (camelCase → kebab-case)"
      (fn []
        (write-file (.. tmp "/fen/models.json")
                    (.. "{\"providers\": {\"ollama\": {"
                        "\"baseUrl\": \"http://localhost:11434/v1\","
                        "\"api\": \"openai-completions\","
                        "\"apiKey\": \"ollama\","
                        "\"compat\": {\"maxTokensField\": \"max_tokens\"},"
                        "\"models\": [{\"id\": \"llama3.1:8b\"}]"
                        "}}}"))
        (let [p (models-mod.get-provider :ollama)]
          (assert.is_table p)
          (assert.are.equal "openai-completions" p.api)
          (assert.are.equal "http://localhost:11434/v1" p.base-url)
          (assert.are.equal "ollama" p.api-key)
          (assert.are.equal "max_tokens" (. p.compat :maxTokensField))
          (assert.are.equal "llama3.1:8b" (. p.models 1 :id)))))

    (it "resolves apiKey via os.getenv when value looks like an env-var name"
      (fn []
        (set fake-env {:MY_OLLAMA_KEY "secret-from-env"})
        ;; core.llm.models reads env lazily during get-provider; fake-env is
        ;; consulted by the os.getenv stub installed in before_each.
        (write-file (.. tmp "/fen/models.json")
                    (.. "{\"providers\": {\"x\": {"
                        "\"baseUrl\": \"https://example.com\","
                        "\"api\": \"openai-completions\","
                        "\"apiKey\": \"MY_OLLAMA_KEY\""
                        "}}}"))
        (let [p (models-mod.get-provider :x)]
          (assert.are.equal "secret-from-env" p.api-key))))

    (it "returns nil api-key when the named env-var is unset"
      (fn []
        (write-file (.. tmp "/fen/models.json")
                    (.. "{\"providers\": {\"x\": {"
                        "\"api\": \"openai-completions\","
                        "\"apiKey\": \"DEFINITELY_NOT_SET_XYZ123\""
                        "}}}"))
        (let [p (models-mod.get-provider :x)]
          (assert.is_nil p.api-key))))

    (it "treats a lowercase apiKey as a literal value"
      (fn []
        (write-file (.. tmp "/fen/models.json")
                    (.. "{\"providers\": {\"x\": {"
                        "\"api\": \"openai-completions\","
                        "\"apiKey\": \"sk-literal\""
                        "}}}"))
        (let [p (models-mod.get-provider :x)]
          (assert.are.equal "sk-literal" p.api-key))))

    (it "exposes first-model-id for default-model selection"
      (fn []
        (write-file (.. tmp "/fen/models.json")
                    (.. "{\"providers\": {\"ollama\": {"
                        "\"api\": \"openai-completions\","
                        "\"models\": [{\"id\": \"qwen2.5-coder:7b\"},"
                        "             {\"id\": \"llama3.1:8b\"}]"
                        "}}}"))
        (let [p (models-mod.get-provider :ollama)]
          (assert.are.equal "qwen2.5-coder:7b"
                            (models-mod.first-model-id p)))))))

(describe "core.llm.models.resolve-api-key"
  (fn []
    (var models-mod nil)
    (before_each
      (fn []
        (set models-mod (h.reload-module :core.llm.models))))

    (it "returns nil for nil / empty input"
      (fn []
        (assert.is_nil (models-mod.resolve-api-key nil))
        (assert.is_nil (models-mod.resolve-api-key ""))))

    (it "passes literal values through unchanged"
      (fn []
        (assert.are.equal "ollama" (models-mod.resolve-api-key "ollama"))
        (assert.are.equal "sk-1234" (models-mod.resolve-api-key "sk-1234"))))

    (it "recognizes UPPER_SNAKE_CASE as an env-var heuristic"
      (fn []
        (assert.is_true (models-mod.looks-like-env-var? "OPENAI_API_KEY"))
        (assert.is_true (models-mod.looks-like-env-var? "X"))
        (assert.is_falsy (models-mod.looks-like-env-var? "ollama"))
        (assert.is_falsy (models-mod.looks-like-env-var? "sk-1234"))
        (assert.is_falsy (models-mod.looks-like-env-var? "Mixed_Case"))))))
