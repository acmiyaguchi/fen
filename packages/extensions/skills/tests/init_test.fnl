;; Tests for extensions.skills — SKILL.md discovery + frontmatter parsing.
;;
;; Strategy: override XDG_CONFIG_HOME and HOME via os.getenv monkey-patch so
;; user-skills-dir resolves under a tmpdir we control. Stub out the
;; project-skills-dir by overriding the module's project-skills-dir function
;; in the loaded module table.

(local h (require :test_helpers))

(local make-tmpdir h.make-tmpdir)
(local rmtree h.rmtree)
(local write-file h.write-file)

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
            (assert.are.equal 1 (length found))))))))

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
              :disable-model-invocation? true}]))))))
