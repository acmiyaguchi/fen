(local provider-help (require :fen.provider_help))

(describe "provider help"
  (fn []
    (it "renders an index with built-in and custom setup pages"
      (fn []
        (let [out (provider-help.render-index)]
          (assert.is_truthy (string.find out "fen provider setup" 1 true))
          (assert.is_truthy (string.find out "openai" 1 true))
          (assert.is_truthy (string.find out "anthropic" 1 true))
          (assert.is_truthy (string.find out "custom / ollama" 1 true)))))

    (it "renders focused OpenAI setup help"
      (fn []
        (let [out (provider-help.render-provider :openai)]
          (assert.is_truthy (string.find out "fen provider: openai" 1 true))
          (assert.is_truthy (string.find out "OPENAI_API_KEY" 1 true))
          (assert.is_truthy (string.find out "fen --provider openai" 1 true)))))

    (it "renders custom provider setup help for Ollama aliases"
      (fn []
        (let [out (provider-help.render-provider :ollama)]
          (assert.is_truthy (string.find out "models.json" 1 true))
          (assert.is_truthy (string.find out "http://localhost:11434/v1" 1 true))
          (assert.is_truthy (provider-help.known-provider? :ollama)))))

    (it "builds first-run missing credential guidance"
      (fn []
        (let [out (provider-help.missing-provider-message :openai :OPENAI_API_KEY)]
          (assert.is_truthy (string.find out "fen needs a configured model provider" 1 true))
          (assert.is_truthy (string.find out "Selected provider: openai" 1 true))
          (assert.is_truthy (string.find out "Missing: OPENAI_API_KEY" 1 true))
          (assert.is_truthy (string.find out "fen providers openai" 1 true)))))))
