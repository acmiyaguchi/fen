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

    (it "returns empty options for unknown APIs"
      (fn []
        (let [opts (thinking.level->provider-options :high :unknown-api)]
          (assert.is_nil (next opts)))))))
