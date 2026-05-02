#!/usr/bin/env fennel

(local fennel (require :fennel))

(local default-src-globals
  "print,pairs,ipairs,tostring,tonumber,require,dofile,os,io,string,table,math,coroutine,error,pcall,xpcall,type,next,select,assert,unpack,rawget,rawset,setmetatable,getmetatable,collectgarbage,_G,bit32,debug")
(local src-globals (or (os.getenv :FNL_SRC_GLOBALS) default-src-globals))
(local test-globals
  (or (os.getenv :FNL_TEST_GLOBALS)
      (.. src-globals ",describe,it,before_each,after_each,setup,teardown,pending,finally,insulate,expose")))

(fn split [s sep]
  (let [out []
        pattern (.. "([^" sep "]+)")]
    (each [part (string.gmatch s pattern)]
      (table.insert out part))
    out))

(fn allowed-globals [csv]
  (let [allowed []]
    ;; The Fennel compiler API's allowedGlobals replaces the default environment
    ;; list, while the CLI's --globals adds to it. Seed from _G to match CLI
    ;; behavior, then append the project-specific names.
    (each [name _ (pairs _G)]
      (table.insert allowed name))
    (each [_ name (ipairs (split csv ","))]
      (table.insert allowed name))
    allowed))

(fn read-all [path]
  (let [f (assert (io.open path :r))
        data (f:read :*a)]
    (f:close)
    data))

(fn write-all [path data]
  (let [f (assert (io.open path :w))]
    (f:write data)
    (f:close)))

(fn shell-quote [s]
  (.. "'" (string.gsub (tostring s) "'" "'\\''") "'"))

(fn command-lines [cmd]
  (let [p (assert (io.popen cmd :r))
        out []]
    (each [line (p:lines)]
      (table.insert out line))
    (let [ok (p:close)]
      (when (not ok)
        (error (.. "command failed: " cmd))))
    out))

(fn first-lines [s n]
  (let [lines []]
    (each [line (string.gmatch (tostring s) "([^\n]*)\n?")]
      (when (and (> (# line) 0) (< (# lines) n))
        (table.insert lines line)))
    (table.concat lines "\n")))

(fn add-path! [field path]
  (let [old (. fennel field)]
    (tset fennel field (if (and old (> (# old) 0))
                         (.. old ";" path)
                         path))))

(fn add-test-paths! []
  (each [_ d (ipairs (command-lines "find packages -path '*/src' -type d | sort"))]
    (add-path! :path (.. "./" d "/?.fnl"))
    (add-path! :path (.. "./" d "/?/init.fnl")))
  (add-path! :path "./tests/?.fnl")
  (add-path! :path "./tests/support/?.fnl")
  (add-path! :path "./tests/?/init.fnl")
  (add-path! :macro-path "./tests/?.fnl")
  (add-path! :macro-path "./tests/support/?.fnl"))

(fn check-file [path globals]
  (let [src (read-all path)
        (ok err) (pcall fennel.compileString src {:filename path
                                                  :allowedGlobals globals})]
    (when (not ok)
      (print (.. "FAIL: " path))
      (print (first-lines err 5)))
    ok))

(fn check-files [files globals]
  (var ok? true)
  (each [_ path (ipairs files)]
    (when (not (check-file path globals))
      (set ok? false)))
  ok?)

(fn read-list [path]
  (let [data (read-all path)
        out []]
    (each [line (string.gmatch data "[^\n]+")]
      (table.insert out line))
    out))

(fn worker-main [list-path add-test-paths?]
  (when add-test-paths?
    (add-test-paths!))
  (os.exit (if (check-files (read-list list-path)
                            (allowed-globals (or (os.getenv :FNL_CHECK_GLOBALS) src-globals)))
             0
             1)))

(fn parse-int [s fallback]
  (or (and s (tonumber s)) fallback))

(fn default-jobs []
  (let [env-jobs (parse-int (or (os.getenv :FENNEL_CHECK_JOBS) (os.getenv :JOBS)) nil)]
    (or env-jobs
        ;; Cap the auto default: many tiny compiler workers hit diminishing
        ;; returns from process startup and disk/cache contention.
        (let [lines (command-lines "getconf _NPROCESSORS_ONLN 2>/dev/null || printf 4")]
          (math.min 16 (parse-int (. lines 1) 4))))))

(fn chunk-files [files jobs prefix tmpdir]
  (let [n (math.max 1 (math.min jobs (# files)))
        chunks []]
    (for [i 1 n]
      (tset chunks i []))
    (each [i file (ipairs files)]
      (table.insert (. chunks (+ (% (- i 1) n) 1)) file))
    (let [paths []]
      (each [i chunk (ipairs chunks)]
        (let [path (.. tmpdir "/" prefix "-" i ".list")]
          (write-all path (.. (table.concat chunk "\n") "\n"))
          (table.insert paths path)))
      paths)))

(fn run-workers [src-files test-files jobs]
  (let [tmpdir (. (command-lines "mktemp -d") 1)
        self (or (. arg 0) "scripts/fennel-check.fnl")
        fennel-cmd (or (os.getenv :FENNEL) "fennel")
        src-chunks (chunk-files src-files jobs :src tmpdir)
        test-chunks (chunk-files test-files jobs :test tmpdir)
        script (.. tmpdir "/run.sh")
        lines ["set -eu" "rc=0" "pids=''" "outs=''" ""]]
    (fn add-worker! [list-path globals add-test?]
      (let [out (.. list-path ".out")]
        (table.insert lines
          (.. "FNL_CHECK_GLOBALS=" (shell-quote globals)
              " " (shell-quote fennel-cmd)
              " " (shell-quote self)
              " --worker " (shell-quote list-path)
              (if add-test? " --test-paths" "")
              " > " (shell-quote out) " 2>&1 &"))
        (table.insert lines "pids=\"$pids $!\"")
        (table.insert lines (.. "outs=\"$outs " out "\""))))
    (each [_ path (ipairs src-chunks)]
      (add-worker! path src-globals false))
    (each [_ path (ipairs test-chunks)]
      (add-worker! path test-globals true))
    (table.insert lines "for pid in $pids; do wait \"$pid\" || rc=1; done")
    (table.insert lines "for out in $outs; do cat \"$out\"; done")
    (table.insert lines (.. "rm -rf " (shell-quote tmpdir)))
    (table.insert lines "exit $rc")
    (write-all script (table.concat lines "\n"))
    (let [ok (os.execute (.. "sh " (shell-quote script)))]
      ok)))

;; Find both `src/`-tree sources (rock-shaped: core, util, fen, providers/*)
;; and flat-layout extension sources at extensions/<kebab>/.
(local src-find
  (.. "find packages extensions -name '*.fnl' -type f"
      " -not -path '*/dist/*'"
      " -not -path '*/tests/*'"
      " -not -path '*/vendor/*'"
      " -not -path '*/.lrbuild/*'"
      " | sort"))

(fn main []
  (when (= (. arg 1) :--worker)
    (worker-main (. arg 2) (= (. arg 3) :--test-paths)))
  (let [src-files (command-lines src-find)
        test-files (command-lines "find packages extensions tests -name '*_test.fnl' -type f | sort")
        ok? (run-workers src-files test-files (default-jobs))]
    (if ok?
      (do (print (.. "All Fennel files check OK. ("
                     (# src-files) " src, "
                     (# test-files) " test, "
                     (+ (# src-files) (# test-files)) " total)"))
          (os.exit 0))
      (os.exit 1))))

(main)
