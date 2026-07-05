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
    (set discover.roots (fn [] roots))
    discover))

(describe "subagent.discover"
  (fn []
    (it "resolves an agent and parses its frontmatter and body"
      (fn []
        (let [base (os.tmpname)]
          (os.remove base)
          (let [user (.. base "/user")
                project (.. base "/project")]
            (mkdir-p user)
            (mkdir-p project)
            (write-file (.. user "/scout.md")
                        "---\nname: scout\ndescription: Recon\nmodel: claude-haiku-4-5\n---\nYou are a scout.\n")
            (let [discover (fresh-discover [{:path project :scope :project}
                                            {:path user :scope :user}])
                  cfg (discover.find-agent :scout)]
              (assert.is_not_nil cfg)
              (assert.are.equal "scout" cfg.name)
              (assert.are.equal "Recon" cfg.description)
              (assert.are.equal "claude-haiku-4-5" cfg.model)
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
                        "---\nname: ok\ndescription: d\ntimeout-seconds: 45\n---\nbody\n")
            (let [discover (fresh-discover [{:path user :scope :user}])]
              (assert.is_nil (. (discover.find-agent :slow) :timeout-seconds))
              (assert.is_nil (. (discover.find-agent :zero) :timeout-seconds))
              (assert.are.equal 45 (. (discover.find-agent :ok) :timeout-seconds))
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
              (os.execute (.. "rm -rf " base)))))))))
