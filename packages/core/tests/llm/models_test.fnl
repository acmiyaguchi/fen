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
        (set models-mod (h.reload-module :fen.core.llm.models))))

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
        (set models-mod (h.reload-module :fen.core.llm.models))))

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
        (set models-mod (h.reload-module :fen.core.llm.models))))

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

(describe "core.llm.models model resolution"
  (fn []
    (var models-mod nil)

    (before_each
      (fn []
        (set models-mod (h.reload-module :fen.core.llm.models))))

    (fn sample-models []
      [{:provider :openai :id :gpt-5.5}
       {:provider :anthropic :id :claude-sonnet-4-6}
       {:provider :ollama :id "llama3.1:8b"}
       {:provider :local :id "llama3.1:8b"}])

    (it "formats canonical provider/model ids"
      (fn []
        (assert.are.equal "openai/gpt-5.5"
                          (models-mod.canonical-model-id
                            {:provider :openai :id :gpt-5.5}))))

    (it "exposes built-in provider defaults"
      (fn []
        (assert.are.equal :gpt-5.4-nano
                          (models-mod.default-model-id :openai))
        (assert.are.equal :claude-sonnet-4-6
                          (models-mod.default-model-id :anthropic))
        (assert.are.equal :openai-completions
                          (models-mod.provider-api :openai))))

    (it "resolves exact canonical provider/model refs"
      (fn []
        (let [result (models-mod.resolve-model "openai/gpt-5.5" (sample-models))]
          (assert.are.equal :ok result.status)
          (assert.are.equal :openai result.model.provider))))

    (it "resolves a unique bare model id"
      (fn []
        (let [result (models-mod.resolve-model "gpt-5.5" (sample-models))]
          (assert.are.equal :ok result.status)
          (assert.are.equal :openai result.model.provider))))

    (it "reports ambiguous bare model ids"
      (fn []
        (let [result (models-mod.resolve-model "llama3.1:8b" (sample-models))]
          (assert.are.equal :ambiguous result.status)
          (assert.are.equal 2 (length result.candidates)))))

    (it "resolves a unique substring for command-mode switching"
      (fn []
        (let [result (models-mod.resolve-model "sonnet" (sample-models))]
          (assert.are.equal :ok result.status)
          (assert.are.equal :anthropic result.model.provider))))

    (it "reports misses"
      (fn []
        (let [result (models-mod.resolve-model "nope" (sample-models))]
          (assert.are.equal :miss result.status)
          (assert.are.equal 0 (length result.candidates)))))))

(describe "core.llm.models.available-models"
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
                (string.match (tostring name) "^[A-Z][A-Z0-9_]*$")
                (. fake-env (tostring name))
                (orig name))))
        (set models-mod (h.reload-module :fen.core.llm.models))))

    (after_each
      (fn []
        (h.restore-getenv!)
        (when tmp (rmtree tmp))))

    (it "lists authless custom provider models"
      (fn []
        (write-file (.. tmp "/fen/models.json")
                    (.. "{\"providers\": {\"ollama\": {"
                        "\"baseUrl\": \"http://localhost:11434/v1\","
                        "\"api\": \"openai-completions\","
                        "\"models\": [{\"id\": \"llama3.1:8b\"}]"
                        "}}}"))
        (let [available (models-mod.available-models {})
              first (. available 1)]
          (assert.are.equal 1 (length available))
          (assert.are.equal :ollama first.provider)
          (assert.are.equal "llama3.1:8b" first.id)
          (assert.are.equal "http://localhost:11434/v1" first.base-url)
          (assert.is_true first.default?))))

    (it "filters unauthenticated built-ins and includes authenticated ones"
      (fn []
        (tset fake-env "OPENAI_API_KEY" "sk-test")
        (let [available (models-mod.available-models {})
              result (models-mod.resolve-model "openai/gpt-5.4-nano" available)
              anthropic (models-mod.resolve-model "anthropic/claude-sonnet-4-6" available)]
          (assert.are.equal :ok result.status)
          (assert.is_true result.model.builtin?)
          (assert.are.equal "sk-test" result.model.api-key)
          (assert.are.equal :miss anthropic.status))))

    (it "includes openai-codex when stored OAuth credentials exist"
      (fn []
        (models-mod.register-builtin-auth-check! :openai-codex (fn [] true))
        (let [available (models-mod.available-models {})
              result (models-mod.resolve-model "openai-codex/gpt-5.5" available)]
          (assert.are.equal :ok result.status)
          (assert.is_true result.model.builtin?)
          (assert.is_nil result.model.api-key)
          (assert.are.equal :openai-codex-responses result.model.api))))))
