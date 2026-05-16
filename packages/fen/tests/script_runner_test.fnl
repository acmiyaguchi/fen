(local runner (require :fen.script_runner))
(local lfs (require :lfs))

(fn write-file [path data]
  (let [f (assert (io.open path :w))]
    (f:write data)
    (f:close)))

(fn read-file [path]
  (let [f (assert (io.open path :r))
        data (f:read :*a)]
    (f:close)
    data))

(fn tmp-path [suffix]
  (.. (os.tmpname) suffix))

(fn tmp-dir []
  (let [path (tmp-path ".d")]
    (os.remove path)
    (assert (lfs.mkdir path))
    path))

(describe "script runner"
  (fn []
    (var saved-arg nil)
    (before_each (fn [] (set saved-arg _G.arg)))
    (after_each (fn [] (set _G.arg saved-arg)))

    (it "parses language flags and script args"
      (fn []
        (let [parsed (runner.parse { 0 "fen" 1 :run 2 :--fennel 3 "tool" 4 "a" 5 "b" })]
          (assert.are.equal "tool" parsed.script)
          (assert.are.equal :fennel parsed.language)
          (assert.are.same ["a" "b"] parsed.args))))

    (it "uses -- to allow script paths that look like options"
      (fn []
        (let [parsed (runner.parse { 0 "fen" 1 :run 2 :-- 3 "--script" 4 "a" })]
          (assert.are.equal "--script" parsed.script)
          (assert.are.equal :lua parsed.language)
          (assert.are.same ["a"] parsed.args))))

    (it "rejects unknown runner options before the script path"
      (fn []
        (let [(parsed err) (runner.parse { 0 "fen" 1 :run 2 :--bad 3 "script.lua" })]
          (assert.is_nil parsed)
          (assert.are.equal "unknown fen run option: --bad" err))))

    (it "parses eval language flags and code args"
      (fn []
        (let [parsed (runner.parse-eval { 0 "fen" 1 :eval 2 :--fennel 3 "(+ 1 2)" 4 "a" 5 "b" })]
          (assert.are.equal "(+ 1 2)" parsed.code)
          (assert.are.equal :fennel parsed.language)
          (assert.are.same ["a" "b"] parsed.args))))

    (it "uses -- to allow eval code that looks like options"
      (fn []
        (let [parsed (runner.parse-eval { 0 "fen" 1 :eval 2 :-- 3 "--not-an-option" 4 "a" })]
          (assert.are.equal "--not-an-option" parsed.code)
          (assert.are.equal :lua parsed.language)
          (assert.are.same ["a"] parsed.args))))

    (it "rejects unknown eval options before the code string"
      (fn []
        (let [(parsed err) (runner.parse-eval { 0 "fen" 1 :eval 2 :--bad 3 "print('no')" })]
          (assert.is_nil parsed)
          (assert.are.equal "unknown fen eval option: --bad" err))))

    (it "infers Fennel only for .fnl paths"
      (fn []
        (assert.are.equal :fennel (runner.infer-language "hello.fnl"))
        (assert.are.equal :lua (runner.infer-language "hello.lua"))
        (assert.are.equal :lua (runner.infer-language "hello"))
        (assert.are.equal :fennel (runner.infer-language "hello" :fennel))))

    (it "builds a Lua-compatible arg table"
      (fn []
        (let [argv { 0 "/bin/fen" 1 :run 2 :--fennel 3 "script.fnl" 4 "one" 5 "two" }
              out (runner.build-arg-table argv 3)
              k-3 -3
              k-2 -2
              k-1 -1]
          (assert.are.equal "/bin/fen" (. out k-3))
          (assert.are.equal :run (. out k-2))
          (assert.are.equal :--fennel (. out k-1))
          (assert.are.equal "script.fnl" (. out 0))
          (assert.are.equal "one" (. out 1))
          (assert.are.equal "two" (. out 2)))))

    (it "builds a Lua-compatible eval arg table"
      (fn []
        (let [argv { 0 "/bin/fen" 1 :eval 2 :--lua 3 "print(...)" 4 "one" 5 "two" }
              out (runner.build-eval-arg-table argv 3)
              k-3 -3
              k-2 -2
              k-1 -1]
          (assert.are.equal "/bin/fen" (. out k-3))
          (assert.are.equal :eval (. out k-2))
          (assert.are.equal :--lua (. out k-1))
          (assert.are.equal "=(fen eval)" (. out 0))
          (assert.are.equal "one" (. out 1))
          (assert.are.equal "two" (. out 2)))))

    (it "runs Lua scripts with arg and varargs"
      (fn []
        (let [script (tmp-path ".lua")
              output (tmp-path ".out")]
          (write-file script "local f = assert(io.open(arg[1], 'w'))\nlocal first, second = ...\nf:write(arg[0] .. '\\n' .. arg[1] .. '\\n' .. tostring(first) .. '\\n' .. tostring(second) .. '\\n' .. tostring(arg[-1]) .. '\\n')\nf:close()\n")
          (assert.are.equal 0 (runner.run! { 0 "fen" 1 :run 2 script 3 output 4 "two" }))
          (assert.are.equal (.. script "\n" output "\n" output "\ntwo\nrun\n")
                            (read-file output))
          (os.remove script)
          (os.remove output))))

    (it "runs Fennel scripts"
      (fn []
        (let [script (tmp-path ".fnl")
              output (tmp-path ".out")]
          (write-file script "(let [f (assert (io.open (. arg 1) :w))]\n  (f:write \"fennel-ok\")\n  (f:close))\n")
          (assert.are.equal 0 (runner.run! { 0 "fen" 1 :run 2 script 3 output }))
          (assert.are.equal "fennel-ok" (read-file output))
          (os.remove script)
          (os.remove output))))

    (it "evaluates Lua code with arg and varargs"
      (fn []
        (let [output (tmp-path ".out")
              code "local first, second = ...\nlocal f = assert(io.open(arg[1], 'w'))\nf:write(arg[0] .. '\\n' .. arg[1] .. '\\n' .. tostring(first) .. '\\n' .. tostring(second) .. '\\n' .. tostring(arg[-1]) .. '\\n')\nf:close()\n"]
          (assert.are.equal 0 (runner.eval! { 0 "fen" 1 :eval 2 code 3 output 4 "two" }))
          (assert.are.equal (.. "=(fen eval)\n" output "\n" output "\ntwo\neval\n")
                            (read-file output))
          (os.remove output))))

    (it "evaluates Fennel code"
      (fn []
        (let [output (tmp-path ".out")]
          (assert.are.equal 0 (runner.eval! { 0 "fen" 1 :eval 2 :--fennel 3 "(let [path ... f (assert (io.open path :w))] (f:write \"fennel-eval\") (f:close))" 4 output }))
          (assert.are.equal "fennel-eval" (read-file output))
          (os.remove output))))

    (it "can force Fennel for extensionless scripts"
      (fn []
        (let [script (tmp-path "")
              output (tmp-path ".out")]
          (write-file script "(let [f (assert (io.open (. arg 1) :w))]\n  (f:write \"forced-fennel\")\n  (f:close))\n")
          (assert.are.equal 0 (runner.run! { 0 "fen" 1 :run 2 :--fennel 3 script 4 output }))
          (assert.are.equal "forced-fennel" (read-file output))
          (os.remove script)
          (os.remove output))))

    (it "lets Fennel scripts require sibling .fnl modules from cwd"
      (fn []
        (let [dir (tmp-dir)
              old-cwd (assert (lfs.currentdir))
              output (.. dir "/out.txt")]
          (write-file (.. dir "/helper.fnl") "{:value \"from-helper\"}\n")
          (write-file (.. dir "/app.fnl") "(let [h (require :helper)\n      f (assert (io.open (. arg 1) :w))]\n  (f:write h.value)\n  (f:close))\n")
          (let [(ok? result) (xpcall
                               (fn []
                                 (assert (lfs.chdir dir))
                                 (assert.are.equal 0 (runner.run! { 0 "fen" 1 :run 2 "app.fnl" 3 output }))
                                 (assert.are.equal "from-helper" (read-file output)))
                               debug.traceback)]
            (assert (lfs.chdir old-cwd))
            (when (not ok?)
              (error result 0))))))))
