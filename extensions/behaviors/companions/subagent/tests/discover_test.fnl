(fn write-file [path content]
  (let [f (assert (io.open path :w))]
    (f:write content)
    (f:close)))

(fn mkdir-p [dir]
  (os.execute (.. "mkdir -p " dir)))

(fn fresh-discover [roots]
  ;; Reload the module and point its roots at our temp dirs. find-agent/list
  ;; resolve (M.roots) at call time, so overriding the table field is enough.
  (tset package.loaded :fen.extensions.subagent.discover nil)
  (let [discover (require :fen.extensions.subagent.discover)]
    (when roots
      (set discover.roots (fn [] roots)))
    discover))

(fn bundled-root []
  {:path "bundled:fen.extensions.subagent.bundled"
   :scope :bundled
   :bundled? true})

(describe "subagent.discover"
  (fn []
    (it "declares project, user, bundled root precedence"
      (fn []
        (let [discover (fresh-discover nil)
              roots (discover.roots)]
          (assert.are.equal :project (. roots 1 :scope))
          (assert.are.equal :user (. roots 2 :scope))
          (assert.are.equal :bundled (. roots 3 :scope))
          (assert.is_true (. roots 3 :bundled?)))))

    (it "finds bundled scout when project and user roots do not define it"
      (fn []
        (let [base (os.tmpname)]
          (os.remove base)
          (let [user (.. base "/user")
                project (.. base "/project")]
            (mkdir-p user)
            (mkdir-p project)
            (let [discover (fresh-discover [{:path project :scope :project}
                                            {:path user :scope :user}
                                            (bundled-root)])
                  cfg (discover.find-agent :scout)]
              (assert.is_not_nil cfg)
              (assert.are.equal "scout" cfg.key)
              (assert.are.equal "scout" cfg.name)
              (assert.are.equal "Fast read-only recon — locate files and answer a focused question"
                                cfg.description)
              (assert.is_nil cfg.model)
              (assert.is_nil cfg.provider)
              (assert.are.equal 90 (. cfg :timeout-seconds))
              (assert.is_nil (. cfg :max-turns))
              (assert.is_nil (. cfg :max-tool-calls))
              (assert.is_truthy (string.find cfg.body "You are a scout" 1 true))
              (os.execute (.. "rm -rf " base)))))))

    (it "lets user and project agents override bundled agents"
      (fn []
        (let [base (os.tmpname)]
          (os.remove base)
          (let [user (.. base "/user")
                project (.. base "/project")]
            (mkdir-p user)
            (mkdir-p project)
            (write-file (.. user "/scout.md")
                        "---\nname: scout\ndescription: user scout\n---\nuser body\n")
            (write-file (.. project "/reviewer.md")
                        "---\nname: reviewer\ndescription: project reviewer\n---\nproject body\n")
            (let [discover (fresh-discover [{:path project :scope :project}
                                            {:path user :scope :user}
                                            (bundled-root)])
                  scout (discover.find-agent :scout)
                  reviewer (discover.find-agent :reviewer)
                  planner (discover.find-agent :planner)]
              (assert.are.equal "user scout" scout.description)
              (assert.is_truthy (string.find scout.body "user body" 1 true))
              (assert.are.equal "project reviewer" reviewer.description)
              (assert.is_truthy (string.find reviewer.body "project body" 1 true))
              (assert.are.equal "Produce a concise, ordered implementation plan for a task"
                                planner.description)
              (os.execute (.. "rm -rf " base)))))))

    (it "resolves an agent and parses its frontmatter and body"
      (fn []
        (let [base (os.tmpname)]
          (os.remove base)
          (let [user (.. base "/user")
                project (.. base "/project")]
            (mkdir-p user)
            (mkdir-p project)
            (write-file (.. user "/scout.md")
                        "---\nname: scout\ndescription: Recon\nmodel: claude-haiku-4-5\nmax-turns: 4\nmax-tool-calls: 10\n---\nYou are a scout.\n")
            (let [discover (fresh-discover [{:path project :scope :project}
                                            {:path user :scope :user}])
                  cfg (discover.find-agent :scout)]
              (assert.is_not_nil cfg)
              (assert.are.equal "scout" cfg.key)
              (assert.are.equal "scout" cfg.name)
              (assert.are.equal "Recon" cfg.description)
              (assert.are.equal "claude-haiku-4-5" cfg.model)
              (assert.are.equal 4 cfg.max-turns)
              (assert.are.equal 10 cfg.max-tool-calls)
              (assert.is_truthy (string.find cfg.body "You are a scout" 1 true))
              (os.execute (.. "rm -rf " base)))))))

    (it "lets a project agent override a user agent of the same name"
      (fn []
        (let [base (os.tmpname)]
          (os.remove base)
          (let [user (.. base "/user")
                project (.. base "/project")]
            (mkdir-p user)
            (mkdir-p project)
            (write-file (.. user "/scout.md")
                        "---\nname: scout\ndescription: user version\n---\nuser body\n")
            (write-file (.. project "/scout.md")
                        "---\nname: scout\ndescription: project version\n---\nproject body\n")
            (let [discover (fresh-discover [{:path project :scope :project}
                                            {:path user :scope :user}])
                  cfg (discover.find-agent :scout)]
              (assert.are.equal "project version" cfg.description)
              (assert.is_truthy (string.find cfg.body "project body" 1 true))
              (os.execute (.. "rm -rf " base)))))))

    (it "ignores a non-numeric or non-positive timeout, falling back to default"
      (fn []
        (let [base (os.tmpname)]
          (os.remove base)
          (let [user (.. base "/user")]
            (mkdir-p user)
            (write-file (.. user "/slow.md")
                        "---\nname: slow\ndescription: d\ntimeout-seconds: fast\n---\nbody\n")
            (write-file (.. user "/zero.md")
                        "---\nname: zero\ndescription: d\ntimeout-seconds: 0\n---\nbody\n")
            (write-file (.. user "/ok.md")
                        "---\nname: ok\ndescription: d\ntimeout-seconds: 45\nmax-turns: 3\nmax-tool-calls: 6\n---\nbody\n")
            (let [discover (fresh-discover [{:path user :scope :user}])]
              (assert.is_nil (. (discover.find-agent :slow) :timeout-seconds))
              (assert.is_nil (. (discover.find-agent :zero) :timeout-seconds))
              (assert.are.equal 45 (. (discover.find-agent :ok) :timeout-seconds))
              (assert.are.equal 3 (. (discover.find-agent :ok) :max-turns))
              (assert.are.equal 6 (. (discover.find-agent :ok) :max-tool-calls))
              (os.execute (.. "rm -rf " base)))))))

    (it "returns nil for an unknown agent"
      (fn []
        (let [base (os.tmpname)]
          (os.remove base)
          (mkdir-p base)
          (let [discover (fresh-discover [{:path base :scope :user}])]
            (assert.is_nil (discover.find-agent :nope))
            (os.execute (.. "rm -rf " base))))))

    (it "reports a present file with no frontmatter as invalid"
      (fn []
        (let [base (os.tmpname)]
          (os.remove base)
          (mkdir-p base)
          (write-file (.. base "/broken.md") "# broken\nbody\n")
          (let [discover (fresh-discover [{:path base :scope :user}])
                (cfg err) (discover.find-agent :broken)]
            (assert.is_nil cfg)
            (assert.is_truthy err)
            (assert.are.equal (.. base "/broken.md") err.file)
            (assert.are.equal "missing frontmatter" err.reason)
            (os.execute (.. "rm -rf " base))))))

    (it "reports a present file missing required name as invalid"
      (fn []
        (let [base (os.tmpname)]
          (os.remove base)
          (mkdir-p base)
          (write-file (.. base "/broken.md")
                      "---\ndescription: no name\n---\nbody\n")
          (let [discover (fresh-discover [{:path base :scope :user}])
                (cfg err) (discover.find-agent :broken)]
            (assert.is_nil cfg)
            (assert.is_truthy err)
            (assert.are.equal "missing required frontmatter field `name`"
                              err.reason)
            (os.execute (.. "rm -rf " base))))))

    (it "reports the highest-precedence invalid candidate"
      (fn []
        (let [base (os.tmpname)]
          (os.remove base)
          (let [user (.. base "/user")
                project (.. base "/project")]
            (mkdir-p user)
            (mkdir-p project)
            (write-file (.. project "/scout.md") "# malformed\n")
            (write-file (.. user "/scout.md")
                        "---\nname: scout\ndescription: user\n---\nbody\n")
            (let [discover (fresh-discover [{:path project :scope :project}
                                            {:path user :scope :user}])
                  (cfg err) (discover.find-agent :scout)]
              (assert.is_nil cfg)
              (assert.is_truthy err)
              (assert.are.equal (.. project "/scout.md") err.file)
              (assert.are.equal "missing frontmatter" err.reason)
              (os.execute (.. "rm -rf " base)))))))

    (it "lists agents across roots, deduped by name with project winning"
      (fn []
        (let [base (os.tmpname)]
          (os.remove base)
          (let [user (.. base "/user")
                project (.. base "/project")]
            (mkdir-p user)
            (mkdir-p project)
            (write-file (.. user "/scout.md")
                        "---\nname: scout\ndescription: user scout\n---\n")
            (write-file (.. user "/planner.md")
                        "---\nname: planner\ndescription: user planner\n---\n")
            (write-file (.. project "/scout.md")
                        "---\nname: scout\ndescription: project scout\n---\n")
            (let [discover (fresh-discover [{:path project :scope :project}
                                            {:path user :scope :user}])
                  agents (discover.list)
                  by-name {}]
              (each [_ a (ipairs agents)]
                (tset by-name a.name a))
              (assert.are.equal 2 (length agents))
              (assert.are.equal "project scout" (. by-name :scout :description))
              (assert.are.equal :project (. by-name :scout :scope))
              (assert.are.equal "user planner" (. by-name :planner :description))
              (os.execute (.. "rm -rf " base)))))))

    (it "keeps the filename key as the launch/display identity"
      (fn []
        (let [base (os.tmpname)]
          (os.remove base)
          (mkdir-p base)
          (write-file (.. base "/custom.md")
                      "---\nname: reviewer\ndescription: custom reviewer\n---\nbody\n")
          (let [discover (fresh-discover [{:path base :scope :project}
                                          (bundled-root)])
                cfg (discover.find-agent :custom)
                agents (discover.list)
                by-key {}]
            (assert.are.equal "custom" cfg.key)
            (assert.are.equal "reviewer" cfg.name)
            (each [_ a (ipairs agents)]
              (tset by-key a.key a))
            (assert.are.equal "custom reviewer" (. by-key :custom :description))
            (assert.are.equal "Review a change or file for correctness, clarity, and risk"
                              (. by-key :reviewer :description))
            (assert.are.equal 300 (. by-key :reviewer :timeout-seconds))
            (assert.are.equal 4 (. by-key :reviewer :max-turns))
            (assert.are.equal 10 (. by-key :reviewer :max-tool-calls))
            (os.execute (.. "rm -rf " base))))))

    (it "lists bundled agents after project and user overrides"
      (fn []
        (let [base (os.tmpname)]
          (os.remove base)
          (let [user (.. base "/user")
                project (.. base "/project")]
            (mkdir-p user)
            (mkdir-p project)
            (write-file (.. user "/scout.md")
                        "---\nname: scout\ndescription: user scout\n---\n")
            (write-file (.. project "/reviewer.md")
                        "---\nname: reviewer\ndescription: project reviewer\n---\n")
            (let [discover (fresh-discover [{:path project :scope :project}
                                            {:path user :scope :user}
                                            (bundled-root)])
                  agents (discover.list)
                  by-name {}]
              (each [_ a (ipairs agents)]
                (tset by-name a.name a))
              (assert.are.equal 3 (length agents))
              (assert.are.equal "user scout" (. by-name :scout :description))
              (assert.are.equal :user (. by-name :scout :scope))
              (assert.are.equal "project reviewer" (. by-name :reviewer :description))
              (assert.are.equal :project (. by-name :reviewer :scope))
              (assert.are.equal "Produce a concise, ordered implementation plan for a task"
                                (. by-name :planner :description))
              (assert.are.equal :bundled (. by-name :planner :scope))
              (os.execute (.. "rm -rf " base)))))))))
