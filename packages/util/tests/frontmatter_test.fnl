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
          (assert.are.equal "30" fields.timeout_seconds))))))
