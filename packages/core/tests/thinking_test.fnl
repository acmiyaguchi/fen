(local thinking (require :fen.core.thinking))

(describe "core.thinking"
  (fn []
    (it "normalizes valid levels"
      (fn []
        (assert.are.equal :medium (thinking.normalize-level "medium"))
        (assert.are.equal :xhigh (thinking.normalize-level "XHIGH"))
        (assert.is_nil (thinking.normalize-level "nope"))))

    (it "maps Anthropic levels to thinking budgets"
      (fn []
        (let [opts (thinking.level->provider-options :high :anthropic-messages)]
          (assert.are.equal 8192 opts.thinking-budget))
        (let [opts (thinking.level->provider-options :off :anthropic-messages)]
          (assert.is_nil opts.thinking-budget))))

    (it "maps OpenAI-compatible levels to reasoning effort"
      (fn []
        (let [opts (thinking.level->provider-options :medium :openai-codex-responses)]
          (assert.are.equal :medium opts.reasoning-effort))
        (let [opts (thinking.level->provider-options :xhigh :openai-responses)]
          (assert.are.equal :xhigh opts.reasoning-effort))))

    (it "forwards the provider-neutral level for every API"
      (fn []
        (assert.are.same {:thinking-level :high}
                         (thinking.level->provider-options :high :unknown-api))
        (assert.are.equal :medium
                          (. (thinking.level->provider-options :medium :anthropic-messages)
                             :thinking-level))))

    (it "returns empty options for off and for a missing or invalid level"
      (fn []
        (assert.is_nil (next (thinking.level->provider-options :off :openai-responses)))
        (assert.is_nil (next (thinking.level->provider-options :off :openrouter-completions)))
        (assert.is_nil (next (thinking.level->provider-options nil :openai-responses)))
        (assert.is_nil (next (thinking.level->provider-options :nope :openai-responses)))))))
