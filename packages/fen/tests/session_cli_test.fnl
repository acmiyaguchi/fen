(local session-cli (require :fen.session_cli))

(describe "fen.session_cli parsing"
  (fn []
    (it "parses an exact-id send with text after the separator"
      (fn []
        (let [(opts err)
              (session-cli.parse {1 :session 2 :send 3 "session-id"
                                  4 :--json 5 :-- 6 "hello" 7 "world"})]
          (assert.is_nil err)
          (assert.are.equal :send opts.verb)
          (assert.are.equal "session-id" opts.session-id)
          (assert.are.equal "hello world" opts.inline-prompt)
          (assert.is_true opts.json?)
          (assert.is_nil (session-cli.validate opts)))))

    (it "accepts safe stdin and file prompt forms"
      (fn []
        (let [(stdin-opts stdin-err)
              (session-cli.parse {1 :session 2 :send 3 "id"
                                  4 :--json 5 :--prompt 6 "-"})
              (file-opts file-err)
              (session-cli.parse {1 :session 2 :send 3 "id"
                                  4 :--json 5 :--prompt-file 6 "request.md"})]
          (assert.is_nil stdin-err)
          (assert.are.equal "-" stdin-opts.prompt)
          (assert.is_nil (session-cli.validate stdin-opts))
          (assert.is_nil file-err)
          (assert.are.equal "request.md" file-opts.prompt-file)
          (assert.is_nil (session-cli.validate file-opts)))))

    (it "requires JSON, one complete id position, and one prompt source"
      (fn []
        (let [(no-json _) (session-cli.parse {1 :session 2 :show 3 "id"})
              (extra _) (session-cli.parse {1 :session 2 :show 3 "id" 4 "extra"
                                            5 :--json})
              (two-prompts _)
              (session-cli.parse {1 :session 2 :send 3 "id" 4 :--json
                                  5 :--prompt 6 "one" 7 :-- 8 "two"})]
          (assert.are.equal "fen session commands require --json"
                            (session-cli.validate no-json))
          (assert.are.equal "fen session show requires exactly one session id"
                            (session-cli.validate extra))
          (assert.are.equal
            "choose exactly one of --prompt, --prompt-file, or text after --"
            (session-cli.validate two-prompts)))))

    (it "rejects invalid and non-integral tail bounds"
      (fn []
        (let [(opts err)
              (session-cli.parse {1 :session 2 :show 3 "id" 4 :--json
                                  5 :--tail 6 "1.5"})]
          (assert.is_nil err)
          (assert.are.equal "--tail must be a non-negative integer"
                            (session-cli.validate opts)))))))
