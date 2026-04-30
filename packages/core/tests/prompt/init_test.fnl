(local h (require :test_helpers))

(describe "core.prompt"
  (fn []
    (var prompt nil)
    (var extensions nil)
    (var tmp nil)

    (before_each
      (fn []
        (set tmp (h.make-tmpdir))
        (h.stub-getenv!
          (fn [name orig]
            (if (= name :HOME) tmp
                (= name :XDG_CONFIG_HOME) nil
                (= name :PWD) (.. tmp "/repo")
                (orig name))))
        (set extensions (require :fen.core.extensions))
        (extensions.reset!)
        (tset package.loaded :fen.extensions.default_prompt nil)
        (tset package.loaded :fen.extensions.default_prompt.resources nil)
        (tset package.loaded :fen.extensions.skills nil)
        (tset package.loaded :fen.core.prompt nil)
        (require :fen.extensions.default_prompt)
        (require :fen.extensions.skills)
        (set prompt (require :fen.core.prompt))))

    (after_each
      (fn []
        (extensions.reset!)
        (h.restore-getenv!)
        (when tmp (h.rmtree tmp))))

    (it "always appends current date and cwd"
      (fn []
        (let [text (prompt.build {:system "custom" :current-date "2026-04-27"}
                                 [])]
          (assert.is_truthy (string.find text "custom" 1 true))
          (assert.is_truthy (string.find text "Current date: 2026-04-27" 1 true))
          (assert.is_truthy (string.find text (.. "Current working directory: " tmp "/repo") 1 true)))))

    (it "renders tool snippets and guidelines before the body"
      (fn []
        (let [text (prompt.build {:system "body" :current-date "2026-04-27"}
                                 [{:name :bash :snippet "Run commands"}
                                  {:name :grep :snippet "Search files"}])]
          (assert.is_truthy (string.find text "Available tools:" 1 true))
          (assert.is_truthy (string.find text "- bash: Run commands" 1 true))
          (assert.is_truthy (string.find text "- grep: Search files" 1 true))
          (assert.is_truthy (string.find text "Prefer grep/find/ls" 1 true))
          (assert.is_truthy (string.find text "multiple tool calls are independent" 1 true)))))

    (it "uses SYSTEM.md as the default body and appends project context and skills"
      (fn []
        ;; Re-require default_prompt after creating resources so its internal
        ;; loader snapshot sees them.
        (h.write-file (.. tmp "/repo/.fen/SYSTEM.md") "system file")
        (h.write-file (.. tmp "/repo/.fen/APPEND_SYSTEM.md") "append file")
        (h.write-file (.. tmp "/repo/CLAUDE.md") "project notes")
        (h.write-file (.. tmp "/.config/fen/skills/s/SKILL.md")
                      "---\ndescription: skill desc\n---\nbody")
        (extensions.reset!)
        (tset package.loaded :fen.extensions.default_prompt nil)
        (tset package.loaded :fen.extensions.default_prompt.resources nil)
        (tset package.loaded :fen.extensions.skills nil)
        (require :fen.extensions.default_prompt)
        (require :fen.extensions.skills)
        (let [text (prompt.build {:current-date "2026-04-27"}
                                 [{:name :read :snippet "Read files"}])]
          (assert.is_truthy (string.find text "system file" 1 true))
          (assert.is_truthy (string.find text "append file" 1 true))
          (assert.is_truthy (string.find text "# Project Context" 1 true))
          (assert.is_truthy (string.find text "project notes" 1 true))
          (assert.is_truthy (string.find text "<available_skills>" 1 true)))))

    (it "does not duplicate first-party fragments after repeated registration"
      (fn []
        (require :fen.extensions.default_prompt)
        (require :fen.extensions.skills)
        (let [listed (extensions.list :prompt-fragments)]
          ;; Requiring the modules twice should unregister/re-register, not
          ;; append another set.
          (assert.are.equal 8 (length listed))
          (assert.are.equal 10 (. listed 1 :order))
          (assert.are.equal :tool-list (. listed 1 :id))
          (assert.are.equal "Available tools" (. listed 1 :title))
          (assert.are.equal 110 (. listed 8 :order)))))))
