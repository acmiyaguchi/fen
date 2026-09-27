;; Portable Lua/Fennel script runner for `fen run`/`fen eval`; intentionally independent of the agent runtime.

(local cli-help (require :fen.cli_help))
(local cli-flags (require :fen.cli_flags))

(local M {})

(local RUN_USAGE (cli-help.for-subcommand :run))

(local EVAL_USAGE
"usage: fen eval [--lua|--fennel] CODE [ARG...]

Evaluate Lua or Fennel code with fen's embedded runtime.
Language is inferred from CODE: leading ( or ; uses Fennel, otherwise Lua.
Use -- before code that starts with '-'. Code args are exposed through Lua-style
arg and varargs. Eval prints return values separated by tabs unless all are nil.
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

;; @doc fen.script_runner.infer-eval-language
;; kind: function
;; signature: (infer-eval-language code ?override) -> :lua|:fennel
;; summary: Choose the eval language, using an explicit override before inferring Fennel from a leading ( or ;.
;; tags: cli scripts eval
(fn M.infer-eval-language [code ?override]
  (or ?override
      (if (string.match (tostring code) "^%s*[(;]") :fennel :lua)))

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
  (let [parsed {}]
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
               :language (M.infer-eval-language code parsed.language)
               :args (copy-script-args argv i)})))))

(fn compile-fennel-code [code filename chunkname]
  (let [fennel (require :fennel)]
    ;; `fen run` and `fen eval` exit after execution, so this mutation cannot leak into agent mode.
    (fennel.install)
    ;; Restrict globals to the live environment so unknown identifiers fail at compile time like fennel.eval.
    (let [globals (icollect [k (pairs _G)] k)
          (compiled lua-or-err) (pcall fennel.compile-string code
                                       {:filename filename :allowedGlobals globals})]
      (if (not compiled)
          (values nil lua-or-err)
          (_G.load lua-or-err chunkname)))))

(fn compile-lua-script [script]
  (_G.loadfile script))

(fn compile-fennel-script [script]
  (let [(f open-err) (io.open script :rb)]
    (if (not f)
        (values nil open-err)
        (let [(source read-err) (f:read :*a)]
          (f:close)
          (if source
              (compile-fennel-code source script (.. "@" script))
              (values nil read-err))))))

(fn compile-lua-eval [code]
  (_G.load code "=(fen eval)"))

(fn compile-eval [parsed]
  (if (= parsed.language :fennel)
      (compile-fennel-code parsed.code "(fen eval)" "=(fen eval)")
      (compile-lua-eval parsed.code)))

(fn compile-script [parsed]
  (if (= parsed.language :fennel)
      (compile-fennel-script parsed.script)
      (compile-lua-script parsed.script)))

(fn runtime-error [err]
  (if (= (os.getenv :FEN_LOG) "debug")
      (debug.traceback err 2)
      err))

(fn run-chunk [chunk args]
  (xpcall (fn [] (chunk (table.unpack args))) runtime-error))

(fn eval-chunk [chunk args]
  (xpcall (fn [] (table.pack (chunk (table.unpack args)))) runtime-error))

(fn print-eval-results [language results]
  "Print returned values REPL-style on one line; print nothing when every value is nil."
  (var any? false)
  (for [i 1 results.n]
    (when (not= (. results i) nil) (set any? true)))
  (when any?
    (let [fennel (and (= language :fennel) (require :fennel))
          out (fcollect [i 1 results.n]
                (let [value (. results i)]
                  (if fennel (fennel.view value) (tostring value))))]
      (io.write (table.concat out "\t") "\n"))))

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
        (do
          (set _G.arg (M.build-arg-table argv parsed.script-index))
          (let [(chunk compile-err) (compile-script parsed)]
            (if (not chunk)
                (do
                  (io.stderr:write (.. (tostring compile-err) "\n"))
                  2)
                (let [(ok? result) (run-chunk chunk parsed.args)]
                  (if ok?
                      0
                      (do
                        (io.stderr:write (.. (tostring result) "\n"))
                        1)))))))))

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
        (do
          (set _G.arg (M.build-eval-arg-table argv parsed.code-index))
          (let [(chunk compile-err) (compile-eval parsed)]
            (if (not chunk)
                (do
                  (io.stderr:write (.. (tostring compile-err) "\n"))
                  2)
                (let [(ok? results) (eval-chunk chunk parsed.args)]
                  (if ok?
                      (do
                        (print-eval-results parsed.language results)
                        0)
                      (do
                        (io.stderr:write (.. (tostring results) "\n"))
                        1)))))))))

M
