(local h (require :test_helpers))

(local make-tmpdir h.make-tmpdir)
(local rmtree h.rmtree)
(local write-file h.write-file)

(describe "core.prompt.resources"
  (fn []
    (var tmp nil)
    (var loader nil)

    (before_each
      (fn []
        (set tmp (make-tmpdir))
        (h.stub-getenv!
          (fn [name orig]
            (if (= name :HOME) tmp
                (= name :XDG_CONFIG_HOME) nil
                (= name :PWD) (.. tmp "/repo/sub")
                (orig name))))
        (set loader (h.reload-module :core.prompt.resources))))

    (after_each
      (fn []
        (h.restore-getenv!)
        (when tmp (rmtree tmp))))

    (it "loads AGENTS/CLAUDE context global then root-to-leaf"
      (fn []
        (write-file (.. tmp "/.pi/agent/AGENTS.md") "global agents")
        (write-file (.. tmp "/repo/CLAUDE.md") "repo claude")
        (write-file (.. tmp "/repo/sub/AGENTS.md") "sub agents")
        (let [found (loader.load-project-context-files (.. tmp "/repo/sub"))]
          (assert.are.equal 3 (length found))
          (assert.is_truthy (string.find (. found 1 :content) "global agents" 1 true))
          (assert.is_truthy (string.find (. found 2 :content) "repo claude" 1 true))
          (assert.is_truthy (string.find (. found 3 :content) "sub agents" 1 true)))))

    (it "uses nearest project SYSTEM.md over global config"
      (fn []
        (write-file (.. tmp "/.config/agent-fennel/SYSTEM.md") "global system")
        (write-file (.. tmp "/repo/.agent-fennel/SYSTEM.md") "repo system")
        (write-file (.. tmp "/repo/sub/.agent-fennel/SYSTEM.md") "sub system")
        (let [sys (loader.load-system-file (.. tmp "/repo/sub") "SYSTEM.md")]
          (assert.is_table sys)
          (assert.are.equal "sub system" sys.content))))

    (it "make returns a reloadable snapshot with cwd and skills"
      (fn []
        (write-file (.. tmp "/.config/agent-fennel/skills/demo/SKILL.md")
          "---\nname: demo\ndescription: Demo skill\n---\n")
        (let [snap (loader.make {})]
          (assert.are.equal (.. tmp "/repo/sub") snap.cwd)
          (assert.are.equal 1 (length snap.skills))
          (assert.are.equal "demo" (. snap.skills 1 :name)))))))
