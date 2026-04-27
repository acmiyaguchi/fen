(local orig-getenv os.getenv)

(fn make-tmpdir []
  (let [base (os.tmpname)]
    (os.remove base)
    (assert (os.execute (.. "mkdir -p '" base "'")))
    base))

(fn rm-rf [path]
  (os.execute (.. "rm -rf '" path "'")))

(fn write-file [path content]
  (assert (os.execute (.. "mkdir -p '" (string.match path "(.*)/") "'")))
  (let [f (assert (io.open path :w))]
    (f:write content)
    (f:close)))

(describe "core.resource_loader"
  (fn []
    (var tmp nil)
    (var loader nil)

    (before_each
      (fn []
        (set tmp (make-tmpdir))
        (set os.getenv (fn [name]
                         (if (= name :HOME) tmp
                             (= name :XDG_CONFIG_HOME) nil
                             (= name :PWD) (.. tmp "/repo/sub")
                             (orig-getenv name))))
        (tset package.loaded :core.resource_loader nil)
        (set loader (require :core.resource_loader))))

    (after_each
      (fn []
        (set os.getenv orig-getenv)
        (when tmp (rm-rf tmp))))

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
