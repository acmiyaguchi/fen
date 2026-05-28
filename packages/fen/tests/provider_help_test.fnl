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

    (it "renders the JSON example block at column 0 so it stays copy-pasteable"
      (fn []
        (let [out (provider-help.render-provider :ollama)]
          ;; The push-block helper must NOT prepend two spaces to JSON body
          ;; lines, otherwise the user's pasted file is malformed.
          (assert.is_truthy (string.find out "\nExample:\n{\n" 1 true))
          (assert.is_truthy (string.find out "\n}\n" 1 true)))))

    (it "builds first-run missing credential guidance"
      (fn []
        (let [out (provider-help.missing-provider-message :openai :OPENAI_API_KEY :default)]
          (assert.is_truthy (string.find out "fen needs a configured model provider" 1 true))
          (assert.is_truthy (string.find out "Active provider: openai (built-in default)" 1 true))
          (assert.is_truthy (string.find out "Missing: OPENAI_API_KEY" 1 true))
          (assert.is_truthy (string.find out "fen providers openai" 1 true)))))

    (it "omits the parenthetical when the provider was set explicitly"
      (fn []
        (let [from-cli (provider-help.missing-provider-message :anthropic :ANTHROPIC_API_KEY :explicit)]
          (assert.is_truthy (string.find from-cli "Active provider: anthropic\n" 1 true))
          (assert.is_nil (string.find from-cli "(built-in default)" 1 true)))))

    (it "omits the `fen providers <name>` deep-link for unknown/extension providers"
      (fn []
        (let [known (provider-help.missing-provider-message :anthropic :ANTHROPIC_API_KEY :explicit)
              extension (provider-help.missing-provider-message :gemini :GEMINI_API_KEY :explicit)]
          (assert.is_truthy (string.find known "fen providers anthropic" 1 true))
          (assert.is_truthy (string.find extension "fen providers" 1 true))
          (assert.is_nil (string.find extension "fen providers gemini" 1 true)))))

    (it "aligns the index columns to the widest provider name"
      (fn []
        (let [out (provider-help.render-index)]
          (assert.is_truthy (string.find out "  openai            Default" 1 true))
          (assert.is_truthy (string.find out "  openai-responses  " 1 true))
          (assert.is_truthy (string.find out "  custom / ollama   OpenAI-compatible" 1 true)))))

    (it "falls back to the index for an unknown provider name"
      (fn []
        (let [out (provider-help.render-provider :no-such-thing)]
          (assert.is_truthy (string.find out "unknown provider setup page: no-such-thing" 1 true))
          (assert.is_truthy (string.find out "fen provider setup" 1 true))
          (assert.is_false (provider-help.known-provider? :no-such-thing)))))

    (it "builds an unknown --provider error message"
      (fn []
        (let [out (provider-help.unknown-provider-message :bogus)]
          (assert.is_truthy (string.find out "unknown --provider: bogus" 1 true))
          (assert.is_truthy (string.find out "models.json" 1 true))
          (assert.is_truthy (string.find out "extension" 1 true))
          (assert.is_truthy (string.find out "fen providers" 1 true)))))

    (it "dispatches `fen providers` to the index with exit 0"
      (fn []
        (let [(out code) (provider-help.dispatch { 0 "fen" 1 :providers })]
          (assert.are.equal 0 code)
          (assert.is_truthy (string.find out "fen provider setup" 1 true)))))

    (it "dispatches `fen providers <name>` to the per-provider page with exit 0"
      (fn []
        (let [(out code) (provider-help.dispatch { 0 "fen" 1 :providers 2 :anthropic })]
          (assert.are.equal 0 code)
          (assert.is_truthy (string.find out "fen provider: anthropic" 1 true)))))

    (it "dispatches Ollama-style aliases via the custom spec with exit 0"
      (fn []
        (let [(out code) (provider-help.dispatch { 0 "fen" 1 :providers 2 :ollama })]
          (assert.are.equal 0 code)
          (assert.is_truthy (string.find out "fen provider: custom" 1 true)))))

    (it "dispatches an unknown provider name with exit 2"
      (fn []
        (let [(out code) (provider-help.dispatch { 0 "fen" 1 :providers 2 :no-such-thing })]
          (assert.are.equal 2 code)
          (assert.is_truthy (string.find out "unknown provider setup page: no-such-thing" 1 true)))))))
