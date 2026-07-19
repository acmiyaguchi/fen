;; Tests for core.llm.models — models.json loader + provider-registry adapter.

(local h (require :fen.testing))
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
(local types (require :fen.core.types))

(local make-tmpdir h.make-tmpdir)
(local rmtree h.rmtree)
(local write-file h.write-file)

(fn register-delegate! []
  (extensions.register
    :provider
    {:name :openai
     :api :openai-completions
     :default-model :gpt-5.4-nano
     :api-key-var :OPENAI_API_KEY
     :complete (fn [model _context options]
                 (types.assistant-message
                   {:api :openai-completions :provider :openai :model model
                    :content [(types.text-block (or options.base-url "ok"))]
                    :stop-reason :stop}))}
    :provider_openai))

(describe "core.llm.models.load"
  (fn []
    (var tmp nil)
    (var models-mod nil)

    (before_each
      (fn []
        (extensions.reset!)
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
        (extensions.reset!)
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
        (extensions.reset!)
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
        (extensions.reset!)
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
        (write-file (.. tmp "/fen/models.json")
                    (.. "{\"providers\": {\"x\": {"
                        "\"baseUrl\": \"https://example.com\","
                        "\"api\": \"openai-completions\","
                        "\"apiKey\": \"MY_OLLAMA_KEY\""
                        "}}}"))
        (let [p (models-mod.get-provider :x)]
          (assert.are.equal "secret-from-env" p.api-key))))

    (it "retains credential provenance when the named env-var is unset"
      (fn []
        (write-file (.. tmp "/fen/models.json")
                    (.. "{\"providers\": {\"x\": {"
                        "\"api\": \"openai-completions\","
                        "\"apiKey\": \"DEFINITELY_NOT_SET_XYZ123\""
                        "}}}"))
        (let [p (models-mod.get-provider :x)]
          (assert.is_nil p.api-key)
          (assert.are.equal "DEFINITELY_NOT_SET_XYZ123" p.api-key-var))))

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

    (it "resolves exact canonical provider/model refs"
      (fn []
        (let [result (models-mod.resolve-model "openai/gpt-5.5" (sample-models))]
          (assert.are.equal :ok result.status)
          (assert.are.equal :openai result.model.provider))))

    (it "splits a canonical provider/model id on the first slash"
      (fn []
        (let [(provider bare) (models-mod.split-model-ref "openai-codex/gpt-5.6-sol")]
          (assert.are.equal "openai-codex" provider)
          (assert.are.equal "gpt-5.6-sol" bare))))

    (it "keeps trailing slashes in the bare model id"
      (fn []
        (let [(provider bare) (models-mod.split-model-ref "vendor/family/model")]
          (assert.are.equal "vendor" provider)
          (assert.are.equal "family/model" bare))))

    (it "round-trips a canonical id through split-model-ref"
      (fn []
        (let [canonical (models-mod.canonical-model-id
                          {:provider :openai :id "gpt-5.5"})
              (provider bare) (models-mod.split-model-ref canonical)]
          (assert.are.equal "openai" provider)
          (assert.are.equal "gpt-5.5" bare))))

    (it "passes bare model ids through untouched"
      (fn []
        (let [(provider bare) (models-mod.split-model-ref "gpt-5.5")]
          (assert.is_nil provider)
          (assert.are.equal "gpt-5.5" bare))))

    (it "does not split a model id whose only slash is inside a colon suffix"
      (fn []
        ;; No leading provider slash: bare id passes through unchanged.
        (let [(provider bare) (models-mod.split-model-ref "llama3.1:8b")]
          (assert.is_nil provider)
          (assert.are.equal "llama3.1:8b" bare))))

    (it "does not split when the provider half is empty"
      (fn []
        (let [(provider bare) (models-mod.split-model-ref "/gpt-5.5")]
          (assert.is_nil provider)
          (assert.are.equal "/gpt-5.5" bare))))

    (it "does not split when the model half is empty"
      (fn []
        (let [(provider bare) (models-mod.split-model-ref "openai/")]
          (assert.is_nil provider)
          (assert.are.equal "openai/" bare))))

    (it "treats nil as an empty bare id"
      (fn []
        (let [(provider bare) (models-mod.split-model-ref nil)]
          (assert.is_nil provider)
          (assert.are.equal "" bare))))

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

    (it "resolves a unique fuzzy model query for command-mode switching"
      (fn []
        (let [result (models-mod.resolve-model "snt46" (sample-models))]
          (assert.are.equal :ok result.status)
          (assert.are.equal :anthropic result.model.provider))))

    (it "resolves a provider query when it uniquely identifies one available model"
      (fn []
        (let [result (models-mod.resolve-model "openai" (sample-models))]
          (assert.are.equal :ok result.status)
          (assert.are.equal :gpt-5.5 result.model.id))))

    (it "reports misses"
      (fn []
        (let [result (models-mod.resolve-model "nope" (sample-models))]
          (assert.are.equal :miss result.status)
          (assert.are.equal 0 (length result.candidates)))))))

(describe "core.llm.models.register-providers!"
  (fn []
    (var tmp nil)
    (var models-mod nil)

    (before_each
      (fn []
        (extensions.reset!)
        (set tmp (make-tmpdir))
        (h.stub-getenv!
          (fn [name orig]
            (if (= name :XDG_CONFIG_HOME) tmp
                (= name :HOME) tmp
                (= name :MY_OLLAMA_KEY) "secret-from-env"
                (orig name))))
        (set models-mod (h.reload-module :fen.core.llm.models))
        (register-delegate!)))

    (after_each
      (fn []
        (h.restore-getenv!)
        (extensions.reset!)
        (when tmp (rmtree tmp))))

    (it "registers models.json providers as executable registry providers"
      (fn []
        (write-file (.. tmp "/fen/models.json")
                    (.. "{\"providers\": {\"ollama\": {"
                        "\"baseUrl\": \"http://localhost:11434/v1\","
                        "\"api\": \"openai-completions\","
                        "\"apiKey\": \"MY_OLLAMA_KEY\","
                        "\"compat\": {\"maxTokensField\": \"max_tokens\"},"
                        "\"models\": [{\"id\": \"llama3.1:8b\"}]"
                        "}}}"))
        (assert.are.equal 1 (models-mod.register-providers!))
        (let [p (extensions.find-provider :ollama)]
          (assert.is_table p)
          (assert.are.equal :models_json p.__owner)
          (assert.are.equal "openai-completions" p.api)
          (assert.are.equal "llama3.1:8b" p.default-model)
          (assert.are.equal "secret-from-env" p.api-key)
          (let [out (p.complete "llama3.1:8b" {:messages []} {:api-key "old"})]
            (assert.are.equal "http://localhost:11434/v1"
                              (types.assistant-text out))))))

    (it "custom provider names override built-in provider names"
      (fn []
        (write-file (.. tmp "/fen/models.json")
                    (.. "{\"providers\": {\"openai\": {"
                        "\"baseUrl\": \"http://proxy/v1\","
                        "\"api\": \"openai-completions\","
                        "\"models\": [{\"id\": \"proxy-model\"}]"
                        "}}}"))
        (models-mod.register-providers!)
        (let [p (extensions.find-provider :openai)]
          (assert.are.equal :models_json p.__owner)
          (assert.are.equal "proxy-model" p.default-model)
          (let [out (p.complete "proxy-model" {:messages []} {})]
            (assert.are.equal "http://proxy/v1" (types.assistant-text out))))))

    (it "skips providers whose api has no non-models-json delegate"
      (fn []
        (write-file (.. tmp "/fen/models.json")
                    (.. "{\"providers\": {\"bad\": {"
                        "\"api\": \"no-such-api\","
                        "\"models\": [{\"id\": \"m\"}]"
                        "}}}"))
        (assert.are.equal 0 (models-mod.register-providers!))
        (assert.is_nil (extensions.find-provider :bad)))))

(describe "core.llm.models.available-models"
  (fn []
    (var tmp nil)
    (var models-mod nil)
    (var fake-env {})

    (before_each
      (fn []
        (extensions.reset!)
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
        (extensions.reset!)
        (when tmp (rmtree tmp))))

    (it "lists authless custom provider models"
      (fn []
        (register-delegate!)
        (write-file (.. tmp "/fen/models.json")
                    (.. "{\"providers\": {\"ollama\": {"
                        "\"baseUrl\": \"http://localhost:11434/v1\","
                        "\"api\": \"openai-completions\","
                        "\"models\": [{\"id\": \"llama3.1:8b\"}]"
                        "}}}"))
        (models-mod.register-providers!)
        (let [available (models-mod.available-models {})
              result (models-mod.resolve-model "ollama/llama3.1:8b" available)
              first result.model]
          (assert.are.equal :ok result.status)
          (assert.are.equal :ollama first.provider)
          (assert.are.equal "llama3.1:8b" first.id)
          (assert.are.equal "http://localhost:11434/v1" first.base-url)
          (assert.is_true first.default?))))

    (it "filters unauthenticated built-ins and includes authenticated ones"
      (fn []
        (tset fake-env "OPENAI_API_KEY" "sk-test")
        (register-delegate!)
        (extensions.register
          :provider
          {:name :anthropic :api :anthropic-messages
           :default-model :claude-sonnet-4-6
           :api-key-var :ANTHROPIC_API_KEY
           :complete (fn [])}
          :provider_anthropic)
        (let [available (models-mod.available-models {})
              result (models-mod.resolve-model "openai/gpt-5.4-nano" available)
              anthropic (models-mod.resolve-model "anthropic/claude-sonnet-4-6" available)]
          (assert.are.equal :ok result.status)
          (assert.is_true result.model.builtin?)
          (assert.are.equal :miss anthropic.status))))

    (it "includes auth-backend providers when their backend is configured"
      (fn []
        (extensions.register
          :auth-backend
          {:name :openai-codex
           :configured? (fn [] true)
           :get-fresh-creds! (fn [] {})}
          :provider_openai)
        (extensions.register
          :provider
          {:name :openai-codex :api :openai-codex-responses
           :default-model :gpt-5.5
           :auth-backend :openai-codex
           :complete (fn [])}
          :provider_openai)
        (let [available (models-mod.available-models {})
              result (models-mod.resolve-model "openai-codex/gpt-5.5" available)]
          (assert.are.equal :ok result.status)
          (assert.is_true result.model.builtin?)
          (assert.is_nil result.model.api-key)
          (assert.are.equal :openai-codex-responses result.model.api))))

    (it "uses and caches dynamic provider model lists"
      (fn []
        (tset fake-env "SAKANA_API_KEY" "sk-test")
        (var calls 0)
        (extensions.register
          :provider
          {:name :sakana :api :openai-responses
           :default-model :fugu-ultra
           :api-key-var :SAKANA_API_KEY
           :models [{:id :fallback}]
           :list-models (fn [opts]
                          (set calls (+ calls 1))
                          (assert.are.equal "sk-test" opts.api-key)
                          [{:id :fugu} {:id :fugu-ultra}])
           :complete (fn [])}
          :provider_sakana)
        (let [first (models-mod.available-models {})
              second (models-mod.available-models {})
              first-result (models-mod.resolve-model "sakana/fugu" first)
              default-result (models-mod.resolve-model "sakana/fugu-ultra" first)
              second-result (models-mod.resolve-model "sakana/fugu" second)
              cache (models-mod.dynamic-cache-snapshot)]
          (assert.are.equal 1 calls)
          (assert.are.equal :ok first-result.status)
          (assert.are.equal :dynamic first-result.model.model-source)
          (assert.is_false first-result.model.default?)
          (assert.are.equal :ok default-result.status)
          (assert.is_true default-result.model.default?)
          (assert.are.equal :ok second-result.status)
          (assert.are.equal :ok (. cache :sakana :status))
          (assert.are.equal 2 (. cache :sakana :model-count)))))

    (it "uses cached/static metadata without starting dynamic discovery"
      (fn []
        (tset fake-env "SAKANA_API_KEY" "sk-test")
        (var calls 0)
        (extensions.register
          :provider
          {:name :sakana :api :openai-responses
           :api-key-var :SAKANA_API_KEY
           :models [{:id :fallback}]
           :list-models (fn [_]
                          (set calls (+ calls 1))
                          [{:id :dynamic}])
           :complete (fn [])}
          :provider_sakana)
        (let [cached (models-mod.available-models {:dynamic-mode :cached})
              cached-result (models-mod.resolve-model "sakana/fallback" cached)]
          (assert.are.equal 0 calls)
          (assert.are.equal :ok cached-result.status)
          (assert.are.equal :static cached-result.model.model-source))
        (models-mod.available-models {})
        (assert.are.equal 1 calls)
        (let [cached (models-mod.available-models {:dynamic-mode :cached})]
          (assert.are.equal :ok
                            (. (models-mod.resolve-model "sakana/dynamic" cached)
                               :status))
          (assert.are.equal 1 calls))))

    (it "falls back to static models when dynamic listing fails"
      (fn []
        (tset fake-env "SAKANA_API_KEY" "sk-test")
        (extensions.register
          :provider
          {:name :sakana :api :openai-responses
           :api-key-var :SAKANA_API_KEY
           :models [{:id :fugu-ultra}]
           :list-models (fn [_] (error "network down"))
           :complete (fn [])}
          :provider_sakana)
        (let [available (models-mod.available-models {})
              result (models-mod.resolve-model "sakana/fugu-ultra" available)
              cache (models-mod.dynamic-cache-snapshot)]
          (assert.are.equal :ok result.status)
          (assert.are.equal :static result.model.model-source)
          (assert.are.equal :failed (. cache :sakana :status))
          (assert.is_true (. cache :sakana :has-error?))))))))
(describe "core.llm.models.inspect-providers"
  (fn []
    (var models-mod nil)
    (var tmp nil)
    (var fake-env {})

    (before_each
      (fn []
        (extensions.reset!)
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
        (extensions.reset!)
        (when tmp (rmtree tmp))))

    (it "marks an unset models.json credential as missing and unavailable"
      (fn []
        (register-delegate!)
        (write-file (.. tmp "/fen/models.json")
                    (.. "{\"providers\": {\"remote\": {"
                        "\"api\": \"openai-completions\","
                        "\"apiKey\": \"REMOTE_TEST_KEY\","
                        "\"models\": [{\"id\": \"remote-model\"}]"
                        "}}}"))
        (models-mod.register-providers!)
        (let [items (models-mod.inspect-providers {} {:provider :remote
                                                       :catalog? true})
              p (. items 1)]
          (assert.are.equal :missing p.auth.status)
          (assert.is_false p.available?)
          (assert.are.equal "remote-model" (. p.models 1 :id))
          (assert.are.equal :miss
                            (. (models-mod.resolve-model
                                 "remote/remote-model"
                                 (models-mod.available-models {}))
                               :status)))))

    (it "reports auth backend configured, missing, error, and absent states"
      (fn []
        (extensions.register :auth-backend
          {:name :ready :configured? (fn [] true)} :test)
        (extensions.register :auth-backend
          {:name :empty :configured? (fn [] false)} :test)
        (extensions.register :auth-backend
          {:name :broken :configured? (fn [] (error "boom"))} :test)
        (each [_ spec (ipairs [{:name :p-ready :auth-backend :ready}
                               {:name :p-empty :auth-backend :empty}
                               {:name :p-broken :auth-backend :broken}
                               {:name :p-absent :auth-backend :absent}])]
          (set spec.api :test)
          (set spec.default-model :m)
          (set spec.complete (fn []))
          (extensions.register :provider spec :test))
        (let [items (models-mod.inspect-providers {} {:catalog? false})
              by-name {}]
          (each [_ p (ipairs items)] (tset by-name p.name p))
          (assert.are.equal :configured (. by-name :p-ready :auth :status))
          (assert.are.equal :missing (. by-name :p-empty :auth :status))
          (assert.are.equal :error (. by-name :p-broken :auth :status))
          (assert.are.equal :backend-missing (. by-name :p-absent :auth :status)))))

    (it "filters inspection and reports dynamic fallback metadata"
      (fn []
        (extensions.register :provider
          {:name :fallback :api :test :api-key "key"
           :models [{:id :static-model}]
           :list-models (fn [_] (error "catalog down"))
           :complete (fn [])}
          :test)
        (extensions.register :provider
          {:name :other :api :test :default-model :other-model
           :complete (fn [])}
          :test)
        (let [items (models-mod.inspect-providers {} {:provider :fallback
                                                       :catalog? true})
              p (. items 1)]
          (assert.are.equal 1 (length items))
          (assert.are.equal :fallback p.name)
          (assert.are.equal :fallback p.catalog.status)
          (assert.are.equal :static p.catalog.source)
          (assert.are.equal :static-model (. p.models 1 :id)))
        (assert.are.equal 0
                          (length (models-mod.inspect-providers {}
                                    {:provider :unknown :catalog? true})))))))
