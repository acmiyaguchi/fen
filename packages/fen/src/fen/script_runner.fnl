;; Portable Lua/Fennel script runner/evaluator for `fen run` and `fen eval`.
;;
;; This module intentionally stays independent of the agent runtime. It is used
;; by early CLI subcommands after the fen-managed rocks tree has been prepended
;; to package.path/package.cpath, then the process exits.

(local cli-help (require :fen.cli_help))
(local cli-flags (require :fen.cli_flags))

(local M {})

(local RUN_USAGE (cli-help.for-subcommand :run))

(local EVAL_USAGE
"usage: fen eval [--lua|--fennel] CODE [ARG...]

Evaluate Lua or Fennel code with fen's embedded runtime.
Lua is the default; use --fennel to evaluate Fennel. Use -- before code
that starts with '-'. Code args are exposed through Lua-style arg and varargs.
")

(fn starts-with? [s prefix]
  (= (string.sub (tostring s) 1 (# prefix)) prefix))

(fn option-token? [token]
  (starts-with? token "-"))

(fn ends-with? [s suffix]
  (let [s (tostring s)
        suffix (tostring suffix)]
    (and (>= (# s) (# suffix))
         (= (string.sub s (+ (- (# s) (# suffix)) 1)) suffix))))

(fn apply-language-flag! [parsed flag]
  (when (= (and flag flag.parse flag.parse.action) :set-const)
    (set parsed.language flag.parse.const)))

(fn copy-script-args [argv script-index]
  (let [out []]
    (for [i (+ script-index 1) (length argv)]
      (table.insert out (. argv i)))
    out))

;; @doc fen.script_runner.usage
;; kind: function
;; signature: (usage) -> string
;; summary: Return command-line usage text for fen run.
;; tags: cli scripts
(fn M.usage [] RUN_USAGE)

;; @doc fen.script_runner.eval-usage
;; kind: function
;; signature: (eval-usage) -> string
;; summary: Return command-line usage text for fen eval.
;; tags: cli scripts eval
(fn M.eval-usage [] EVAL_USAGE)

;; @doc fen.script_runner.infer-language
;; kind: function
;; signature: (infer-language script ?override) -> :lua|:fennel
;; summary: Choose the runner language, using an explicit override before script extension inference.
;; tags: cli scripts
(fn M.infer-language [script ?override]
  (or ?override
      (if (ends-with? script ".fnl") :fennel :lua)))

;; @doc fen.script_runner.build-arg-table
;; kind: function
;; signature: (build-arg-table argv script-index) -> table
;; summary: Build a Lua-compatible global arg table for a script selected from fen's original argv.
;; tags: cli scripts compatibility
(fn M.build-arg-table [argv script-index]
  "Map fen's argv into Lua's script convention: arg[0] is the script,
   positive indexes are script arguments, and negative indexes are the
   interpreter/subcommand tokens that preceded the script."
  (let [out {}]
    (for [i 0 (length argv)]
      (let [v (. argv i)]
        (when v
          (tset out (- i script-index) v))))
    out))

;; @doc fen.script_runner.build-eval-arg-table
;; kind: function
;; signature: (build-eval-arg-table argv code-index) -> table
;; summary: Build a Lua-compatible global arg table for inline eval code.
;; tags: cli scripts eval compatibility
(fn M.build-eval-arg-table [argv code-index]
  "Map fen's argv for eval mode. arg[0] is a synthetic chunk name,
   positive indexes are eval arguments, and negative indexes are the
   interpreter/subcommand/options that preceded the code string."
  (let [out {0 "=(fen eval)"}]
    (for [i 0 (- code-index 1)]
      (let [v (. argv i)]
        (when v
          (tset out (- i code-index) v))))
    (for [i (+ code-index 1) (length argv)]
      (let [v (. argv i)]
        (when v
          (tset out (- i code-index) v))))
    out))

;; @doc fen.script_runner.parse
;; kind: function
;; signature: (parse argv) -> table|nil, err|nil
;; summary: Parse fen run arguments without invoking the general agent option parser.
;; tags: cli scripts
(fn M.parse [argv]
  (var i 2)
  (let [parsed {}]
    (var parsing-options? true)
    (var err nil)
    (while (and parsing-options? (not err) (<= i (length argv)))
      (let [token (. argv i)]
        (if (= token :--)
            (do
              (set parsing-options? false)
              (set i (+ i 1)))
            (let [flag (and (option-token? token) (cli-flags.find token :run))]
              (if flag
                  (if (= flag.name "--help")
                      (set err :help)
                      (do
                        (apply-language-flag! parsed flag)
                        (set i (+ i 1))))
                  (option-token? token)
                  (set err (cli-flags.unknown-message token :run))
                  (set parsing-options? false))))))
    (if err
        (values nil err)
        (let [script (. argv i)]
          (if (not script)
              (values nil :missing-script)
              {:script script
               :script-index i
               :language (M.infer-language script parsed.language)
               :args (copy-script-args argv i)})))))

;; @doc fen.script_runner.parse-eval
;; kind: function
;; signature: (parse-eval argv) -> table|nil, err|nil
;; summary: Parse fen eval arguments without invoking the general agent option parser.
;; tags: cli scripts eval
(fn M.parse-eval [argv]
  (var i 2)
  (let [parsed {:language :lua}]
    (var parsing-options? true)
    (var err nil)
    (while (and parsing-options? (not err) (<= i (length argv)))
      (let [token (. argv i)]
        (if (= token :--)
            (do
              (set parsing-options? false)
              (set i (+ i 1)))
            (let [flag (and (option-token? token) (cli-flags.find token :eval))]
              (if flag
                  (if (= flag.name "--help")
                      (set err :help)
                      (do
                        (apply-language-flag! parsed flag)
                        (set i (+ i 1))))
                  (option-token? token)
                  (set err (cli-flags.unknown-message token :eval))
                  (set parsing-options? false))))))
    (if err
        (values nil err)
        (let [code (. argv i)]
          (if (not code)
              (values nil :missing-code)
              {:code code
               :code-index i
               :language parsed.language
               :args (copy-script-args argv i)})))))

(fn run-lua-script [script script-args]
  (let [(chunk err) (_G.loadfile script)]
    (when (not chunk)
      (error err 0))
    (chunk (table.unpack script-args))))

(fn run-fennel-script [script script-args]
  (let [fennel (require :fennel)]
    ;; Install Fennel's package.searchers entry in runner mode so sibling
    ;; helper.fnl modules can be required from script projects. `fen run`
    ;; exits after execution, so the global searcher mutation cannot leak into
    ;; the agent runtime.
    (fennel.install)
    (fennel.dofile script {} (table.unpack script-args))))

(fn eval-lua-code [code code-args]
  (let [(chunk err) (_G.load code "=(fen eval)")]
    (when (not chunk)
      (error err 0))
    (chunk (table.unpack code-args))))

(fn eval-fennel-code [code code-args]
  (let [fennel (require :fennel)]
    (fennel.install)
    (fennel.eval code {:filename "=(fen eval)"} (table.unpack code-args))))

(fn execute [argv parsed]
  (set _G.arg (M.build-arg-table argv parsed.script-index))
  (if (= parsed.language :fennel)
      (run-fennel-script parsed.script parsed.args)
      (run-lua-script parsed.script parsed.args)))

(fn execute-eval [argv parsed]
  (set _G.arg (M.build-eval-arg-table argv parsed.code-index))
  (if (= parsed.language :fennel)
      (eval-fennel-code parsed.code parsed.args)
      (eval-lua-code parsed.code parsed.args)))

;; @doc fen.script_runner.run!
;; kind: function
;; signature: (run! argv) -> integer
;; summary: Run the script selected by fen run and return the process exit code.
;; tags: cli scripts
(fn M.run! [argv]
  (let [(parsed err) (M.parse argv)]
    (if (not parsed)
        (if (= err :help)
            (do
              (io.write RUN_USAGE)
              0)
            (do
              (when (and err (not= err :missing-script))
                (io.stderr:write (.. (tostring err) "\n")))
              (io.stderr:write RUN_USAGE)
              2))
        (let [(ok? result) (xpcall (fn [] (execute argv parsed)) debug.traceback)]
          (if ok?
              0
              (do
                (io.stderr:write (.. (tostring result) "\n"))
                1))))))

;; @doc fen.script_runner.eval!
;; kind: function
;; signature: (eval! argv) -> integer
;; summary: Evaluate the code selected by fen eval and return the process exit code.
;; tags: cli scripts eval
(fn M.eval! [argv]
  (let [(parsed err) (M.parse-eval argv)]
    (if (not parsed)
        (if (= err :help)
            (do
              (io.write EVAL_USAGE)
              0)
            (do
              (when (and err (not= err :missing-code))
                (io.stderr:write (.. (tostring err) "\n")))
              (io.stderr:write EVAL_USAGE)
              2))
        (let [(ok? result) (xpcall (fn [] (execute-eval argv parsed)) debug.traceback)]
          (if ok?
              0
              (do
                (io.stderr:write (.. (tostring result) "\n"))
                1))))))

M
