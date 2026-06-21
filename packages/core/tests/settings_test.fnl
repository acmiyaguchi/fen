;; Tests for core.settings — ~/.config/fen/settings.json loader/writer.

(local h (require :fen.testing))

(local make-tmpdir h.make-tmpdir)
(local rmtree h.rmtree)
(local write-file h.write-file)
(local read-file h.read-file)

(describe "core.settings"
  (fn []
    (var tmp nil)
    (var settings nil)

    (before_each
      (fn []
        (set tmp (make-tmpdir))
        (h.stub-getenv!
          (fn [name orig]
            (if (= name :XDG_CONFIG_HOME) tmp
                (= name :HOME) tmp
                (orig name))))
        (set settings (h.reload-module :fen.core.settings))))

    (after_each
      (fn []
        (h.restore-getenv!)
        (when tmp (rmtree tmp))))

    (it "returns an empty normalized record when settings.json is missing"
      (fn []
        (let [out (settings.load)]
          (assert.is_table out)
          (assert.is_nil out.default-provider)
          (assert.is_nil out.default-model)
          (assert.is_nil out.default-thinking))))

    (it "returns an empty normalized record for malformed JSON"
      (fn []
        (write-file (.. tmp "/fen/settings.json") "{not valid json")
        (let [out (settings.load)]
          (assert.is_table out)
          (assert.is_nil out.default-provider)
          (assert.is_nil out.default-model)
          (assert.is_nil out.default-thinking))))

    (it "normalizes pi-mono-compatible camelCase keys"
      (fn []
        (write-file (.. tmp "/fen/settings.json")
                    "{\"defaultProvider\":\"openai-codex\",\"defaultModel\":\"gpt-5.5\",\"defaultThinking\":\"high\"}")
        (let [out (settings.load)]
          (assert.are.equal "openai-codex" out.default-provider)
          (assert.are.equal "gpt-5.5" out.default-model)
          (assert.are.equal "high" out.default-thinking))))

    (it "writes default provider/model atomically and can read them back"
      (fn []
        (settings.set-defaults! :openai-codex :gpt-5.5)
        (assert.is_nil (read-file (.. tmp "/fen/settings.json.tmp")))
        (let [out (settings.load)]
          (assert.are.equal :openai-codex out.default-provider)
          (assert.are.equal :gpt-5.5 out.default-model))))

    (it "adopts provider/model as the default when nothing is selected yet"
      (fn []
        (assert.is_true (settings.adopt-default-if-unset! :openai-codex :gpt-5.5))
        (let [out (settings.load)]
          (assert.are.equal :openai-codex out.default-provider)
          (assert.are.equal :gpt-5.5 out.default-model))))

    (it "leaves an existing default provider untouched on adoption"
      (fn []
        (write-file (.. tmp "/fen/settings.json")
                    "{\"defaultProvider\":\"anthropic\",\"defaultModel\":\"claude-haiku-4-5\"}")
        (assert.is_false (settings.adopt-default-if-unset! :openai-codex :gpt-5.5))
        (let [out (settings.load)]
          (assert.are.equal "anthropic" out.default-provider)
          (assert.are.equal "claude-haiku-4-5" out.default-model))))

    (it "writes default thinking atomically and can read it back"
      (fn []
        (settings.set-thinking-default! :high)
        (assert.is_nil (read-file (.. tmp "/fen/settings.json.tmp")))
        (let [out (settings.load)]
          (assert.are.equal :high out.default-thinking))))

    (it "preserves unknown top-level keys when saving defaults"
      (fn []
        (write-file (.. tmp "/fen/settings.json")
                    "{\"theme\":\"dark\",\"defaultProvider\":\"openai\"}")
        (settings.set-defaults! :anthropic :claude-sonnet-4-6)
        (let [raw (read-file (.. tmp "/fen/settings.json"))]
          (assert.is_truthy (string.find raw "\"theme\":\"dark\"" 1 true)))
        (let [out (settings.load)]
          (assert.are.equal :anthropic out.default-provider)
          (assert.are.equal :claude-sonnet-4-6 out.default-model))))

    (it "preserves provider/model when saving default thinking"
      (fn []
        (write-file (.. tmp "/fen/settings.json")
                    "{\"defaultProvider\":\"openai\",\"defaultModel\":\"gpt-5.5\"}")
        (settings.set-thinking-default! :medium)
        (let [out (settings.load)]
          (assert.are.equal "openai" out.default-provider)
          (assert.are.equal "gpt-5.5" out.default-model)
          (assert.are.equal :medium out.default-thinking))))))
