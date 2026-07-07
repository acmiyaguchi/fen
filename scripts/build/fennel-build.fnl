#!/usr/bin/env fennel
;; Bootstrap build driver.
;;
;; Compiles the workspace (default) or a single rock's .lrbuild/ tree
;; (`--lrbuild`) using bare `fennel`, before any `fen` binary exists. All the
;; actual compile rules (file walk, excludes, source->output mapping, skills
;; data blob) live in `fen.core.extensions.build`; this file only owns CLI
;; parsing and the parallel worker fan-out.

(local fennel (require :fennel))

;; Load the shared `fen.core.extensions.build` module from the workspace source
;; relative to this script, so bare `fennel` picks it up from any cwd (workspace
;; root during packaging, or a rock dir during a standalone `luarocks make`).
;; `fennel.dofile` is deterministic across fennel install flavors, unlike a
;; `require` that depends on how the searcher paths are configured.
(local build
  (let [self (or (. arg 0) "scripts/build/fennel-build.fnl")
        root (or (string.match self "^(.-)scripts/build/fennel%-build%.fnl$") "")]
    (fennel.dofile (.. root "packages/core/src/fen/core/extensions/build.fnl"))))

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

(fn read-list [path]
  (let [data (read-all path)
        out []]
    (each [line (string.gmatch data "[^\n]+")]
      (table.insert out line))
    out))

(fn worker-main [list-path lrbuild?]
  (os.exit (if (build.build-files (read-list list-path)
                                  (if lrbuild?
                                      build.lrbuild-output-path
                                      build.workspace-output-path))
             0
             1)))

(fn parse-int [s fallback]
  (or (and s (tonumber s)) fallback))

(fn default-jobs []
  (let [env-jobs (parse-int (or (os.getenv :FENNEL_BUILD_JOBS) (os.getenv :JOBS)) nil)]
    (or env-jobs
        ;; Compile jobs are tiny; too many workers can be slower than a cap.
        (let [lines (command-lines "getconf _NPROCESSORS_ONLN 2>/dev/null || printf 4")]
          (math.min 16 (parse-int (. lines 1) 4))))))

(fn chunk-files [files jobs tmpdir]
  (let [n (math.max 1 (math.min jobs (# files)))
        chunks []]
    (for [i 1 n]
      (tset chunks i []))
    (each [i file (ipairs files)]
      (table.insert (. chunks (+ (% (- i 1) n) 1)) file))
    (let [paths []]
      (each [i chunk (ipairs chunks)]
        (let [path (.. tmpdir "/build-" i ".list")]
          (write-all path (.. (table.concat chunk "\n") "\n"))
          (table.insert paths path)))
      paths)))

(fn run-workers [files jobs lrbuild?]
  (let [tmpdir (. (command-lines "mktemp -d") 1)
        self (or (. arg 0) "scripts/build/fennel-build.fnl")
        fennel-cmd (or (os.getenv :FENNEL) "fennel")
        chunks (chunk-files files jobs tmpdir)
        script (.. tmpdir "/run.sh")
        lines ["set -eu" "rc=0" "pids=''" "outs=''" ""]]
    (each [_ list-path (ipairs chunks)]
      (let [out (.. list-path ".out")]
        (table.insert lines
          (.. (shell-quote fennel-cmd)
              " " (shell-quote self)
              " --worker " (shell-quote list-path)
              (if lrbuild? " --lrbuild" "")
              " > " (shell-quote out) " 2>&1 &"))
        (table.insert lines "pids=\"$pids $!\"")
        (table.insert lines (.. "outs=\"$outs " out "\""))))
    (table.insert lines "for pid in $pids; do wait \"$pid\" || rc=1; done")
    (table.insert lines "for out in $outs; do cat \"$out\"; done")
    (table.insert lines (.. "rm -rf " (shell-quote tmpdir)))
    (table.insert lines "exit $rc")
    (write-all script (table.concat lines "\n"))
    (os.execute (.. "sh " (shell-quote script)))))

(fn main []
  (when (= (. arg 1) :--worker)
    (worker-main (. arg 2) (= (. arg 3) :--lrbuild)))
  (let [lrbuild? (= (. arg 1) :--lrbuild)
        files (command-lines (if lrbuild? build.lrbuild-find build.workspace-find))]
    (when lrbuild?
      (os.execute "rm -rf .lrbuild"))
    (let [ok? (run-workers files (default-jobs) lrbuild?)]
      (when ok?
        (build.generate-bundled-skills-data
          (if lrbuild?
              ".lrbuild/extensions/skills/bundled_data.lua"
              "extensions/behaviors/companions/skills/dist/fen/extensions/skills/bundled_data.lua")
          (if lrbuild? "bundled" nil)))
      (os.exit (if ok? 0 1)))))

(main)
