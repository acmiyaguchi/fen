;; Tests for interactive slash command formatting/dispatch.

(describe "commands /status"
  (fn []
    (it "includes the build version"
      (fn []
        (tset package.loaded :version "test-version")
        (var appended nil)
        (tset package.loaded :tui.tui
              {:append-event (fn [ev] (set appended ev))})
        (let [commands (require :core.commands)
              state {:opts {:provider :openai}
                     :agent {:model :gpt-test
                             :provider-api :openai-completions
                             :max-tokens 123
                             :system-prompt "system"
                             :messages []}
                     :session nil}]
          (commands.handle "/status" state)
          (assert.are.equal :assistant-text appended.type)
          (assert.is_not_nil (string.find appended.text "version: test-version" 1 true)))))))
