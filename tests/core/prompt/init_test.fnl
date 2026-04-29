(describe "core.prompt"
  (fn []
    (var prompt nil)
    (var extensions nil)

    (before_each
      (fn []
        (set extensions (require :core.extensions))
        (extensions.reset!)
        (tset package.loaded :extensions.default_prompt nil)
        (tset package.loaded :extensions.skills nil)
        (require :extensions.default_prompt)
        (require :extensions.skills)
        (tset package.loaded :core.prompt nil)
        (set prompt (require :core.prompt))))

    (after_each
      (fn []
        (extensions.reset!)))

    (it "always appends current date and cwd"
      (fn []
        (let [text (prompt.build {:system "custom" :current-date "2026-04-27"}
                                 {:cwd "/work" :skills [] :context-files []}
                                 [])]
          (assert.is_truthy (string.find text "custom" 1 true))
          (assert.is_truthy (string.find text "Current date: 2026-04-27" 1 true))
          (assert.is_truthy (string.find text "Current working directory: /work" 1 true)))))

    (it "renders tool snippets and guidelines before the body"
      (fn []
        (let [text (prompt.build {:system "body" :current-date "2026-04-27"}
                                 {:cwd "/repo" :skills []}
                                 [{:name :bash :snippet "Run commands"}
                                  {:name :grep :snippet "Search files"}])]
          (assert.is_truthy (string.find text "Available tools:" 1 true))
          (assert.is_truthy (string.find text "- bash: Run commands" 1 true))
          (assert.is_truthy (string.find text "- grep: Search files" 1 true))
          (assert.is_truthy (string.find text "Prefer grep/find/ls" 1 true))
          (assert.is_truthy (string.find text "multiple tool calls are independent" 1 true)))))

    (it "uses SYSTEM.md as the default body and appends project context and skills"
      (fn []
        (let [text (prompt.build {:current-date "2026-04-27"}
                                 {:cwd "/repo"
                                  :system-md {:path "/repo/.fen/SYSTEM.md"
                                              :content "system file"}
                                  :append-system-md {:path "/repo/.fen/APPEND_SYSTEM.md"
                                                     :content "append file"}
                                  :context-files [{:path "/repo/CLAUDE.md"
                                                   :content "project notes"}]
                                  :skills [{:name "s" :description "skill desc"
                                            :path "/skills/s/SKILL.md"}]}
                                 [{:name :read :snippet "Read files"}])]
          (assert.is_truthy (string.find text "system file" 1 true))
          (assert.is_truthy (string.find text "append file" 1 true))
          (assert.is_truthy (string.find text "# Project Context" 1 true))
          (assert.is_truthy (string.find text "project notes" 1 true))
          (assert.is_truthy (string.find text "<available_skills>" 1 true)))))

    (it "does not duplicate first-party fragments after repeated registration"
      (fn []
        (require :extensions.default_prompt)
        (require :extensions.skills)
        (let [listed (extensions.list :prompt-fragments)]
          ;; Requiring the modules twice should unregister/re-register, not
          ;; append another set.
          (assert.are.equal 8 (length listed))
          (assert.are.equal 10 (. listed 1 :order))
          (assert.are.equal 110 (. listed 8 :order)))))))
