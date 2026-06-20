(local frontmatter (require :fen.util.frontmatter))

(describe "util.frontmatter"
  (fn []
    (it "parses fields and body from valid frontmatter"
      (fn []
        (let [(fields body) (frontmatter.parse
                              "---\nname: scout\ndescription: Fast recon\n---\nBody line one.\nBody line two.\n")]
          (assert.are.equal "scout" fields.name)
          (assert.are.equal "Fast recon" fields.description)
          (assert.are.equal "Body line one.\nBody line two.\n" body))))

    (it "strips surrounding quotes from values"
      (fn []
        (let [(fields _) (frontmatter.parse
                           "---\nname: \"quoted name\"\ndescription: 'single quoted'\n---\nbody")]
          (assert.are.equal "quoted name" fields.name)
          (assert.are.equal "single quoted" fields.description))))

    (it "returns an empty body when no closing delimiter is present"
      (fn []
        (let [(fields body) (frontmatter.parse "---\nname: x\ndescription: y\n")]
          (assert.are.equal "x" fields.name)
          (assert.are.equal "" body))))

    (it "returns nil when the text does not start with a delimiter"
      (fn []
        (assert.is_nil (frontmatter.parse "no frontmatter here\nname: x\n"))))

    (it "returns nil on empty input"
      (fn []
        (assert.is_nil (frontmatter.parse ""))))

    (it "keeps a closing delimiter that has no trailing newline"
      (fn []
        (let [(fields body) (frontmatter.parse "---\nname: x\n---")]
          (assert.are.equal "x" fields.name)
          (assert.are.equal "" body))))

    (it "preserves keys with dashes and underscores"
      (fn []
        (let [(fields _) (frontmatter.parse
                           "---\ndisable-model-invocation: true\ntimeout_seconds: 30\n---\n")]
          (assert.are.equal "true" (. fields "disable-model-invocation"))
          (assert.are.equal "30" fields.timeout_seconds))))

    (it "parse-file reads the body only when asked"
      (fn []
        (let [p (os.tmpname)
              f (assert (io.open p :w))]
          (f:write "---\nname: x\n---\nbody line\n")
          (f:close)
          (let [(_ body-without) (frontmatter.parse-file p)
                (fields body-with) (frontmatter.parse-file p true)]
            (assert.are.equal "" body-without)
            (assert.are.equal "x" fields.name)
            (assert.are.equal "body line\n" body-with))
          (os.remove p))))

    (it "parse-file distinguishes unreadable from missing frontmatter"
      (fn []
        (let [(meta reason err) (frontmatter.parse-file "/no/such/file.md")]
          (assert.is_nil meta)
          (assert.are.equal :unreadable reason)
          (assert.is_truthy err))
        (let [p (os.tmpname)
              f (assert (io.open p :w))]
          (f:write "not frontmatter\nname: x\n")
          (f:close)
          (let [(meta reason) (frontmatter.parse-file p)]
            (assert.is_nil meta)
            (assert.are.equal :no-frontmatter reason))
          (os.remove p))))))
