(local session-cli (require :fen.session_cli))
(local json (require :fen.util.json))
(local process (require :fen.util.process))
(local testing (require :fen.testing))

(fn command-output [command]
  (let [pipe (assert (io.popen command :r))
        output (pipe:read :*l)]
    (pipe:close)
    output))

(fn repo-root [] (command-output "git rev-parse --show-toplevel"))
(fn fen-bin [] (or (os.getenv :FEN_BIN) (command-output "command -v fen")))

(fn shell-args [args]
  (table.concat (icollect [_ arg (ipairs args)]
                  (testing.shellquote arg)) " "))

(fn run-session [root state work args]
  "Run the development launcher as a child, retaining stdout separately from
   diagnostics so the machine protocol can be asserted byte-for-byte."
  (let [_ (assert (os.execute (.. "mkdir -p " (testing.shellquote state))))
        stdout (.. state "/stdout.json")
        stderr (.. state "/stderr.log")
        command (.. "exec " (testing.shellquote (.. root "/scripts/dev/fen-dev"))
                    " " (shell-args args)
                    " >" (testing.shellquote stdout)
                    " 2>" (testing.shellquote stderr))
        result (process.run-captured {:argv ["/bin/sh" "-c" command]
                                      :cwd work
                                      :env {:PATH (or (os.getenv :PATH) "/usr/bin:/bin")
                                            :HOME (or (os.getenv :HOME) "/tmp")
                                            :FEN_BIN (fen-bin)
                                            :XDG_STATE_HOME state
                                            :XDG_CONFIG_HOME (.. state "/config")}})]
    {:exit-code result.exit-code
     :stdout (or (testing.read-file stdout) "")
     :stderr (or (testing.read-file stderr) "")
     :launcher-output result.output
     :launcher-signal result.signal}))

(fn assert-json-document [run]
  (assert.is_truthy (string.match run.stdout "\n$")
                     (.. "stdout: " run.stdout "\\nstderr: " run.stderr
                         "\\nlauncher: " (or run.launcher-output "")
                         " signal=" (tostring run.launcher-signal)))
  (assert.are.equal 1 (select 2 (string.gsub run.stdout "\n" "")))
  (let [(ok? document) (pcall json.decode run.stdout)]
    (assert.is_true ok? (.. "stdout was not JSON: " run.stdout))
    document))

(fn write-noisy-extension [dir]
  (testing.write-file
    (.. dir "/init.fnl")
    "(io.write \"io.write noise\\n\")\n(print \"print noise\")\n(io.stdout:write \"stdout noise\\n\")\n{:register (fn [_] true)}\n")
  dir)

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

(describe "fen session machine protocol subprocesses"
  (fn []
    (var root nil)
    (var tmp nil)

    (before_each
      (fn []
        (set root (repo-root))
        (set tmp (testing.make-tmpdir))))

    (after_each
      (fn []
        (when tmp (testing.rmtree tmp))))

    (it "keeps durable new, list, and show stdout to one JSON document despite extension output"
      (fn []
        (let [state (.. tmp "/state")
              work (.. tmp "/work")
              noisy (write-noisy-extension (.. tmp "/noisy"))]
          (assert.is_truthy (os.execute (.. "mkdir -p " (testing.shellquote work))))
          (let [created-run (run-session root state work
                                         ["session" "new" "--json" "--extension" noisy])
                created (assert-json-document created-run)]
            (assert.are.equal 0 created-run.exit-code)
            (assert.is_true created.ok)
            (let [id created.session.id
                  listed-run (run-session root state work
                                          ["session" "list" "--json" "--extension" noisy])
                  listed (assert-json-document listed-run)
                  shown-run (run-session root state work
                                         ["session" "show" id "--json" "--extension" noisy])
                  shown (assert-json-document shown-run)]
              (assert.are.equal 0 listed-run.exit-code)
              (assert.are.equal id (. listed.sessions 1 :id))
              (assert.are.equal 0 shown-run.exit-code)
              (assert.are.equal id shown.session.id)
              (assert.are.equal 0 (length shown.messages)))))))

    (it "persists a mock-provider turn and uses it as continuation context in separate processes"
      (fn []
        (let [state (.. tmp "/state")
              work (.. tmp "/work")
              mock "provider_mock"]
          (assert.is_truthy (os.execute (.. "mkdir -p " (testing.shellquote work))))
          (let [created (assert-json-document
                          (run-session root state work ["session" "new" "--json"]))
                id created.session.id
                first-run (run-session root state work
                                       ["session" "send" id "--json" "--extension" mock
                                        "--provider" "mock" "--" "first"])
                first (assert-json-document first-run)
                second-run (run-session root state work
                                        ["session" "send" id "--json" "--extension" mock
                                         "--provider" "mock" "--" "second"])
                second (assert-json-document second-run)]
            (assert.are.equal 0 first-run.exit-code)
            (assert.are.equal "[mock] first" first.turn.result)
            (assert.are.equal 2 (length first.turn.messages))
            (assert.are.equal 0 second-run.exit-code)
            (assert.are.equal "[mock] second" second.turn.result)
            ;; The returned turn is isolated, while the durable transcript
            ;; replayed by the second process contains the first complete turn.
            (assert.are.equal 2 (length second.turn.messages))))))))
