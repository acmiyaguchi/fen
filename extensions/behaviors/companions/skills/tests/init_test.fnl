;; Tests for extensions.skills — SKILL.md discovery + frontmatter parsing.
;;
;; Strategy: override XDG_CONFIG_HOME and HOME via os.getenv monkey-patch so
;; user-skills-dir resolves under a tmpdir we control. Stub out the
;; project-skills-dir by overriding the module's project-skills-dir function
;; in the loaded module table.

(local h (require :fen.testing))
(local test-api (require :fen.core.extensions.test_api))

(local make-tmpdir h.make-tmpdir)
(local rmtree h.rmtree)
(local write-file h.write-file)

(fn find-skill [skills name]
  (var found nil)
  (each [_ skill (ipairs skills)]
    (when (= skill.name name)
      (set found skill)))
  found)

(describe "extensions.skills.parse-frontmatter"
  (fn []
    (var tmp nil)
    (var skills-mod nil)

    (before_each
      (fn []
        (set tmp (make-tmpdir))
        (set skills-mod (h.reload-module :fen.extensions.skills))))

    (after_each (fn [] (when tmp (rmtree tmp))))

    (it "parses name + description from valid frontmatter"
      (fn []
        (let [path (.. tmp "/SKILL.md")]
          (write-file path "---\nname: hello\ndescription: Greets\n---\n\nbody\n")
          (let [meta (skills-mod.parse-frontmatter path)]
            (assert.is_table meta)
            (assert.are.equal "hello" meta.name)
            (assert.are.equal "Greets" meta.description)))))

    (it "strips surrounding quotes from values"
      (fn []
        (let [path (.. tmp "/SKILL.md")]
          (write-file path "---\nname: \"quoted\"\ndescription: 'also'\n---\n")
          (let [meta (skills-mod.parse-frontmatter path)]
            (assert.are.equal "quoted" meta.name)
            (assert.are.equal "also" meta.description)))))

    (it "parses disable-model-invocation"
      (fn []
        (let [path (.. tmp "/hidden/SKILL.md")]
          (write-file path "---\ndescription: Hidden\ndisable-model-invocation: true\n---\n")
          (let [meta (skills-mod.parse-frontmatter path)]
            (assert.is_true meta.disable-model-invocation?)))))

    (it "returns nil when the file lacks frontmatter"
      (fn []
        (let [path (.. tmp "/SKILL.md")]
          (write-file path "no frontmatter here\n")
          (assert.is_nil (skills-mod.parse-frontmatter path)))))

    (it "uses the parent directory as name fallback"
      (fn []
        (let [path (.. tmp "/fallback/SKILL.md")]
          (write-file path "---\ndescription: Has fallback name\n---\n")
          (let [meta (skills-mod.parse-frontmatter path)]
            (assert.is_table meta)
            (assert.are.equal "fallback" meta.name)
            (assert.are.equal "Has fallback name" meta.description)))))

    (it "returns nil when description is missing"
      (fn []
        (let [path (.. tmp "/SKILL.md")]
          (write-file path "---\nname: solo\n---\n")
          (assert.is_nil (skills-mod.parse-frontmatter path)))))

    (it "returns nil for nonexistent files"
      (fn []
        (assert.is_nil (skills-mod.parse-frontmatter (.. tmp "/missing.md")))))))

(describe "extensions.skills.discover"
  (fn []
    (var tmp nil)
    (var skills-mod nil)

    (before_each
      (fn []
        (set tmp (make-tmpdir))
        ;; Pretend HOME = tmp so user-skills-dir = tmp/.config/fen/skills
        (h.stub-getenv!
          (fn [name orig]
            (if (= name :HOME) tmp
                (= name :XDG_CONFIG_HOME) nil
                (= name :XDG_DATA_HOME) tmp
                (= name :FEN_DISABLE_BUNDLED_SKILLS) "1"
                (= name :PWD) tmp
                (orig name))))
        (set skills-mod (h.reload-module :fen.extensions.skills))))

    (after_each
      (fn []
        (h.restore-getenv!)
        (when tmp (rmtree tmp))))

    (it "discovers a valid skill directory"
      (fn []
        (let [skills-dir (.. tmp "/.config/fen/skills")]
          (write-file (.. skills-dir "/greeter/SKILL.md")
            "---\nname: greeter\ndescription: Greets the user\n---\n\nbody")
          (let [found (skills-mod.discover [])]
            (assert.are.equal 1 (length found))
            (assert.are.equal "greeter" (. found 1 :name))
            (assert.are.equal "Greets the user" (. found 1 :description))
            (assert.are.equal :user (. found 1 :scope))))))

    (it "skips directories without SKILL.md"
      (fn []
        (let [skills-dir (.. tmp "/.config/fen/skills")]
          (write-file (.. skills-dir "/no-skill/notes.md") "just notes\n")
          (let [found (skills-mod.discover [])]
            (assert.are.equal 0 (length found))))))

    (it "skips skills with malformed frontmatter without crashing"
      (fn []
        (let [skills-dir (.. tmp "/.config/fen/skills")]
          (write-file (.. skills-dir "/bad/SKILL.md") "no frontmatter\n")
          (write-file (.. skills-dir "/good/SKILL.md")
            "---\nname: good\ndescription: works\n---\n")
          (let [found (skills-mod.discover [])]
            (assert.are.equal 1 (length found))
            (assert.are.equal "good" (. found 1 :name))))))

    (it "discovers nested skill directories recursively"
      (fn []
        (let [skills-dir (.. tmp "/.config/fen/skills")]
          (write-file (.. skills-dir "/group/nested/SKILL.md")
            "---\nname: nested\ndescription: nested skill\n---\n")
          (let [found (skills-mod.discover [])]
            (assert.are.equal 1 (length found))
            (assert.are.equal "nested" (. found 1 :name))))))

    (it "discovers direct .md skills under .pi/skills"
      (fn []
        (write-file (.. tmp "/.pi/skills/quick.md")
          "---\ndescription: Quick skill\n---\n")
        (let [found (skills-mod.discover [])]
          (assert.are.equal 1 (length found))
          (assert.are.equal "quick" (. found 1 :name))
          (assert.are.equal "Quick skill" (. found 1 :description)))))

    (it "honors .ignore files while scanning a skills root"
      (fn []
        (let [skills-dir (.. tmp "/.config/fen/skills")]
          (write-file (.. skills-dir "/.ignore") "ignored/\n")
          (write-file (.. skills-dir "/ignored/SKILL.md")
            "---\nname: ignored\ndescription: should not load\n---\n")
          (write-file (.. skills-dir "/visible/SKILL.md")
            "---\nname: visible\ndescription: should load\n---\n")
          (let [found (skills-mod.discover [])]
            (assert.are.equal 1 (length found))
            (assert.are.equal "visible" (. found 1 :name))))))

    (it "honors ancestor .gitignore files for project skill roots"
      (fn []
        (write-file (.. tmp "/.gitignore") ".agents/skills/secret/\n")
        (write-file (.. tmp "/.agents/skills/secret/SKILL.md")
          "---\nname: secret\ndescription: hidden\n---\n")
        (write-file (.. tmp "/.agents/skills/public/SKILL.md")
          "---\nname: public\ndescription: visible\n---\n")
        (let [found (skills-mod.discover [])]
          (assert.are.equal 1 (length found))
          (assert.are.equal "public" (. found 1 :name)))))

    (it "honors .fdignore for direct .md skills under .pi/skills"
      (fn []
        (write-file (.. tmp "/.fdignore") ".pi/skills/ignored.md\n")
        (write-file (.. tmp "/.pi/skills/ignored.md")
          "---\ndescription: hidden\n---\n")
        (write-file (.. tmp "/.pi/skills/keep.md")
          "---\ndescription: visible\n---\n")
        (let [found (skills-mod.discover [])]
          (assert.are.equal 1 (length found))
          (assert.are.equal "keep" (. found 1 :name)))))

    (it "merges --skill extra dirs (tagged scope=:cli)"
      (fn []
        (let [extra (.. tmp "/extras")]
          (write-file (.. extra "/x/SKILL.md")
            "---\nname: x\ndescription: extra\n---\n")
          (let [found (skills-mod.discover [extra])]
            (assert.are.equal 1 (length found))
            (assert.are.equal "x" (. found 1 :name))
            (assert.are.equal :cli (. found 1 :scope))))))

    (it "deduplicates a SKILL.md that's reachable through multiple roots"
      (fn []
        (let [skills-dir (.. tmp "/.config/fen/skills")]
          (write-file (.. skills-dir "/dup/SKILL.md")
            "---\nname: dup\ndescription: once\n---\n")
          (let [found (skills-mod.discover [skills-dir])]
            (assert.are.equal 1 (length found))))))

    (it "materializes and discovers bundled fen skills"
      (fn []
        (h.stub-getenv!
          (fn [name orig]
            (if (= name :HOME) tmp
                (= name :XDG_CONFIG_HOME) nil
                (= name :XDG_DATA_HOME) tmp
                (= name :FEN_DISABLE_BUNDLED_SKILLS) nil
                (= name :PWD) tmp
                (orig name))))
        (let [found (skills-mod.discover [])
              author (find-skill found "fen-extension-author")
              introspect (find-skill found "fen-source-introspection")]
          (assert.are.equal 2 (length found))
          (assert.is_table author)
          (assert.are.equal :builtin author.scope)
          (assert.is_truthy
            (string.find author.path
                         "/fen/skills/bundled/fen-extension-author/SKILL.md"
                         1 true))
          (assert.is_table introspect)
          (assert.are.equal :builtin introspect.scope)
          (assert.is_truthy
            (string.find introspect.path
                         "/fen/skills/bundled/fen-source-introspection/SKILL.md"
                         1 true)))))

    (it "accepts a cooperative yield while scanning roots"
      (fn []
        (let [skills-dir (.. tmp "/.config/fen/skills")]
          (write-file (.. skills-dir "/coop/SKILL.md")
            "---\nname: coop\ndescription: cooperative\n---\n")
          (var yields 0)
          (let [found (skills-mod.discover [] (fn [] (set yields (+ yields 1))))]
            (assert.are.equal 1 (length found))
            (assert.are.equal "coop" (. found 1 :name))
            (assert.is_true (> yields 0))))))

    (it "lets user skills shadow bundled skills by name"
      (fn []
        (h.stub-getenv!
          (fn [name orig]
            (if (= name :HOME) tmp
                (= name :XDG_CONFIG_HOME) nil
                (= name :XDG_DATA_HOME) tmp
                (= name :FEN_DISABLE_BUNDLED_SKILLS) nil
                (= name :PWD) tmp
                (orig name))))
        (write-file (.. tmp "/.config/fen/skills/fen-extension-author/SKILL.md")
          "---\nname: fen-extension-author\ndescription: user override\n---\n")
        (let [found (skills-mod.discover [])
              author (find-skill found "fen-extension-author")
              introspect (find-skill found "fen-source-introspection")]
          (assert.are.equal 2 (length found))
          (assert.is_table author)
          (assert.are.equal "user override" author.description)
          (assert.are.equal :user author.scope)
          (assert.is_table introspect)
          (assert.are.equal :builtin introspect.scope))))))

(describe "extensions.skills.system-prompt-section"
  (fn []
    (var skills-mod nil)
    (before_each
      (fn []
        (set skills-mod (h.reload-module :fen.extensions.skills))))

    (it "returns nil when no skills are present"
      (fn []
        (assert.is_nil (skills-mod.system-prompt-section []))
        (assert.is_nil (skills-mod.system-prompt-section nil))))

    (it "renders Agent Skills XML with name, path, and description"
      (fn []
        (let [text (skills-mod.system-prompt-section
                     [{:name "greeter" :path "/x/SKILL.md"
                       :description "Greets" :scope :user}])]
          (assert.is_string text)
          (assert.is_truthy (string.find text "<available_skills>" 1 true))
          (assert.is_truthy (string.find text "<name>greeter</name>" 1 true))
          (assert.is_truthy (string.find text "/x/SKILL.md" 1 true))
          (assert.is_truthy (string.find text "<description>Greets</description>" 1 true)))))

    (it "omits disable-model-invocation skills from the prompt"
      (fn []
        (assert.is_nil
          (skills-mod.system-prompt-section
            [{:name "hidden" :path "/x/SKILL.md" :description "Hidden"
              :disable-model-invocation? true}]))))

    (it "renders a /skills report with scope, visibility, and paths"
      (fn []
        (let [text (skills-mod.skills-text
                     [{:name "visible" :path "/x/visible/SKILL.md"
                       :description "Visible" :scope :builtin}
                      {:name "hidden" :path "/x/hidden/SKILL.md"
                       :description "Hidden" :scope :user
                       :disable-model-invocation? true}])]
          (assert.is_truthy (string.find text "# Skills (2 shown, 1 visible, 1 hidden)" 1 true))
          (assert.is_truthy (string.find text "visible" 1 true))
          (assert.is_truthy (string.find text "builtin" 1 true))
          (assert.is_truthy (string.find text "/x/visible/SKILL.md" 1 true))
          (assert.is_truthy (string.find text "hidden" 1 true)))))

    (it "filters the /skills report"
      (fn []
        (let [text (skills-mod.skills-text
                     [{:name "visible" :path "/x/visible/SKILL.md"
                       :description "Visible" :scope :builtin}
                      {:name "hidden" :path "/x/hidden/SKILL.md"
                       :description "Hidden" :scope :user
                       :disable-model-invocation? true}]
                     "hidden")]
          (assert.is_truthy (string.find text "# Skills (1 shown, 1 visible, 1 hidden)" 1 true))
          (assert.is_nil (string.find text "/x/visible/SKILL.md" 1 true))
          (assert.is_truthy (string.find text "/x/hidden/SKILL.md" 1 true)))))))

(local register-test-state {})

(fn setup-register-test []
  (set register-test-state.tmp (make-tmpdir))
  (h.stub-getenv!
    (fn [name orig]
      (if (= name :HOME) register-test-state.tmp
          (= name :XDG_CONFIG_HOME) nil
          (= name :XDG_DATA_HOME) register-test-state.tmp
          (= name :FEN_DISABLE_BUNDLED_SKILLS) "1"
          (= name :PWD) register-test-state.tmp
          (orig name))))
  (set register-test-state.skills-mod (h.reload-module :fen.extensions.skills))
  (set register-test-state.api (test-api.make :skills))
  register-test-state)

(fn teardown-register-test []
  (h.restore-getenv!)
  (when register-test-state.tmp (rmtree register-test-state.tmp))
  (set register-test-state.tmp nil)
  (set register-test-state.skills-mod nil)
  (set register-test-state.api nil))

(describe "extensions.skills.register"
  (fn []
    (it "registers prompt fragment, /skills command, and introspector"
      (fn []
        (let [s (setup-register-test)]
          (s.skills-mod.register s.api)
          (assert.are.equal 1 (length s.api.captured.prompts))
          (assert.are.equal 1 (length s.api.captured.commands))
          (assert.are.equal :skills (. s.api.captured.commands 1 :spec :name))
          (assert.are.equal 1 (length s.api.captured.introspectors))
          (assert.are.equal :discovered-skills (. s.api.captured.introspectors 1 :spec :name))
          (teardown-register-test))))

    (it "/skills list emits discovered skill paths"
      (fn []
        (let [s (setup-register-test)]
          (write-file (.. s.tmp "/.config/fen/skills/demo/SKILL.md")
            "---\nname: demo\ndescription: Demo skill\n---\n")
          (s.skills-mod.register s.api)
          ((. s.api.captured.commands 1 :spec :handler) "list" {:opts {}})
          (assert.are.equal 1 (length s.api.captured.events-out))
          (let [ev (. s.api.captured.events-out 1)]
            (assert.are.equal :assistant-text ev.type)
            (assert.is_truthy (string.find ev.text "demo" 1 true))
            (assert.is_truthy (string.find ev.text "/demo/SKILL.md" 1 true)))
          (teardown-register-test))))

    (it "introspector snapshots discovered skills"
      (fn []
        (let [s (setup-register-test)]
          (write-file (.. s.tmp "/.config/fen/skills/demo/SKILL.md")
            "---\nname: demo\ndescription: Demo skill\n---\n")
          (s.skills-mod.register s.api)
          (let [snap ((. s.api.captured.introspectors 1 :spec :snapshot) {:opts {}})]
            (assert.are.equal 1 snap.count)
            (assert.are.equal 1 snap.visible-count)
            (assert.are.equal "demo" (. snap.skills 1 :name)))
          (teardown-register-test))))))
