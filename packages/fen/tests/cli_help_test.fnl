(local cli-help (require :fen.cli_help))
(local provider-help (require :fen.provider_help))
(local runner (require :fen.script_runner))

(fn contains? [s needle]
  (not= nil (string.find s needle 1 true)))

(fn count-literal [s needle]
  (var count 0)
  (var start 1)
  (var done? false)
  (while (not done?)
    (let [idx (string.find s needle start true)]
      (if idx
          (do
            (set count (+ count 1))
            (set start (+ idx (length needle))))
          (set done? true))))
  count)

(local FENNEL-CMD
  "fennel --add-fennel-path 'packages/fen/src/?.fnl' --add-fennel-path 'packages/core/src/?.fnl' --add-fennel-path 'packages/util/src/?.fnl' packages/fen/src/fen/main.fnl")

(fn run-main [args]
  (let [p (assert (io.popen (.. FENNEL-CMD " " args " 2>&1")))
        out (p:read :*a)
        (ok _why code) (p:close)]
    (values out (if (= ok true) 0 (or code 1)))))

(describe "CLI subcommand help"
  (fn []
    (it "defines focused help for all issue-340 subcommands"
      (fn []
        (each [_ name (ipairs [:goal :list :show :run :providers])]
          (let [out (cli-help.for-subcommand name)]
            (assert.is_not_nil out)
            (assert.is_truthy (contains? out (.. "fen " (tostring name))))
            (assert.is_truthy (contains? out "Usage:"))
            (assert.is_truthy (contains? out "Options:"))
            (assert.is_truthy (contains? out "Exit codes"))
            (assert.are.equal 1 (count-literal out "Example:"))
            ;; Focused subcommand help must not be the top-level monolith.
            (assert.is_false (contains? out "Slash commands (interactive mode):"))
            (assert.is_false (contains? out "Subcommands:"))))))

    (it "documents the goal 0/2/1 exit-code contract prominently"
      (fn []
        (let [out (cli-help.for-subcommand :goal)]
          (assert.is_truthy (contains? out "Exit codes (goal contract):"))
          (assert.is_truthy (contains? out "0  Done"))
          (assert.is_truthy (contains? out "2  Not done"))
          (assert.is_truthy (contains? out "1  Failure")))))

    (it "uses focused run help from the script runner"
      (fn []
        (let [out (runner.usage)]
          (assert.are.equal (cli-help.for-subcommand :run) out)
          (assert.is_truthy (contains? out "fen run [--lua|--fennel] <script> [args...]"))
          (assert.is_truthy (contains? out "--fennel"))
          (assert.is_truthy (contains? out "Script load/runtime failure")))))

    (it "dispatches `fen providers --help` to focused providers help with exit 0"
      (fn []
        (let [(out code) (provider-help.dispatch {0 "fen" 1 :providers 2 :--help})]
          (assert.are.equal 0 code)
          (assert.is_truthy (contains? out "Usage:"))
          (assert.is_truthy (contains? out "fen providers [name]"))
          (assert.is_truthy (contains? out "Exit codes:"))
          (assert.is_false (contains? out "fen provider setup")))))

    (it "prefers focused providers help over a provider setup page when --help follows a name"
      (fn []
        (let [(out code) (provider-help.dispatch {0 "fen" 1 :providers 2 :openai 3 :--help})]
          (assert.are.equal 0 code)
          (assert.is_truthy (contains? out "fen providers [name]"))
          ;; Must not render the openai-specific setup page.
          (assert.is_false (contains? out "fen provider: openai")))))

    (it "still renders a named provider setup page without --help"
      (fn []
        (let [(out code) (provider-help.dispatch {0 "fen" 1 :providers 2 :openai})]
          (assert.are.equal 0 code)
          (assert.is_truthy (contains? out "fen provider: openai")))))

    (it "short top-level help is concise, example-rich, and free of internals"
      (fn []
        (let [out (cli-help.top-level)]
          (assert.is_not_nil out)
          (assert.is_truthy (contains? out "Usage:"))
          (assert.is_truthy (contains? out "Examples:"))
          ;; Agent-oriented discovery stays near the top.
          (assert.is_truthy (contains? out "Agent-oriented discovery:"))
          ;; Pointers to focused and exhaustive help.
          (assert.is_truthy (contains? out "fen <command> --help"))
          (assert.is_truthy (contains? out "fen --help-all"))
          ;; Copy-pasteable real invocations from the issue.
          (assert.is_truthy (contains? out "fen --no-session --tools read,grep,find,ls --print"))
          (assert.is_truthy (contains? out "fen goal --max-iterations 10"))
          (assert.is_truthy (contains? out "FEN_JSON_OUTPUT_PATH=out.json fen --presenter json --print"))
          (assert.is_truthy (contains? out "fen --provider openai-codex --model gpt-5.6-sol --print"))
          (assert.is_truthy (contains? out "fen --continue"))
          ;; Launcher internals and slash-command minutiae belong in --help-all.
          (assert.is_false (contains? out "--dev-path"))
          (assert.is_false (contains? out "--extension-root"))
          (assert.is_false (contains? out "FEN_DEV_PATH"))
          (assert.is_false (contains? out "Slash commands (interactive mode):"))
          ;; The short help must actually be shorter than the exhaustive one.
          (assert.is_true (< (length out) (length (cli-help.top-level-all)))))))

    (it "exhaustive top-level help keeps launcher internals and env-var minutiae"
      (fn []
        (let [out (cli-help.top-level-all)]
          (assert.is_not_nil out)
          (assert.is_truthy (contains? out "--dev-path"))
          (assert.is_truthy (contains? out "--extension-root"))
          (assert.is_truthy (contains? out "FEN_DEV_PATH"))
          (assert.is_truthy (contains? out "FEN_EXTENSION_ROOT"))
          (assert.is_truthy (contains? out "Slash commands (interactive mode):"))
          (assert.is_truthy (contains? out "Environment:"))
          (assert.is_truthy (contains? out "Subcommands:")))))

    (it "recognizes --help-all"
      (fn []
        (assert.is_truthy (cli-help.help-all? :--help-all))
        (assert.is_truthy (cli-help.help-all? "--help-all"))
        (assert.is_false (cli-help.help-all? :--help))))

    (it "routes `fen --help` and `fen -h` to the short top-level help with exit 0"
      (fn []
        (each [_ args (ipairs ["--help" "-h"])]
          (let [(out code) (run-main args)]
            (assert.are.equal 0 code)
            (assert.is_truthy (contains? out "Examples:"))
            (assert.is_truthy (contains? out "fen --help-all"))
            (assert.is_false (contains? out "--dev-path"))
            (assert.is_false (contains? out "Slash commands (interactive mode):"))))))

    (it "routes `fen --help-all` to the exhaustive help with exit 0"
      (fn []
        (let [(out code) (run-main "--help-all")]
          (assert.are.equal 0 code)
          (assert.is_truthy (contains? out "--dev-path"))
          (assert.is_truthy (contains? out "FEN_DEV_PATH"))
          (assert.is_truthy (contains? out "Slash commands (interactive mode):")))))

    (it "routes real subcommand --help invocations through main with exit 0"
      (fn []
        (each [_ scenario (ipairs [{:args "goal --help" :usage "fen goal [options] <objective>"}
                                   {:args "list --help" :usage "fen list [surface]"}
                                   {:args "show --help" :usage "fen show <surface> <name>"}
                                   {:args "run --help" :usage "fen run [--lua|--fennel] <script>"}
                                   {:args "providers --help" :usage "fen providers [name]"}])]
          (let [(out code) (run-main scenario.args)]
            (assert.are.equal 0 code)
            (assert.is_truthy (contains? out scenario.usage))
            (assert.is_truthy (contains? out "Exit codes"))
            (assert.is_truthy (contains? out "Example:"))
            (assert.is_false (contains? out "unknown discovery option: --help"))
            (assert.is_false (contains? out "Slash commands (interactive mode):"))))))))
