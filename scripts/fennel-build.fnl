#!/usr/bin/env fennel

(local fennel (require :fennel))

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

(fn dirname [path]
  (or (string.match path "^(.+)/[^/]+$") "."))

(fn file-exists? [path]
  (let [f (io.open path :r)]
    (if f (do (f:close) true) false)))

;; Manifest-name cache. Flat-layout extensions live at
;; extensions/<kebab>/{manifest.fnl,init.fnl,...} and the build
;; needs the manifest's :name to map flat sources to namespaced output
;; (dist/fen/extensions/<snake>/...). We read the manifest text and parse
;; :name with a regex — manifests are literal tables so no Fennel eval is
;; needed at build bootstrap time.
(local manifest-name-cache {})

(fn parse-manifest-name [text]
  (or (string.match text ":name%s+:([%w_%-]+)")
      (string.match text ":name%s+\"([^\"]+)\"")))

(fn read-manifest-name [pkg-dir]
  (when (= nil (. manifest-name-cache pkg-dir))
    (let [path (.. pkg-dir "/manifest.fnl")]
      (if (file-exists? path)
          (let [f (io.open path :r)
                data (f:read :*a)]
            (f:close)
            (tset manifest-name-cache pkg-dir
                  (or (parse-manifest-name data) false)))
          (tset manifest-name-cache pkg-dir false))))
  (let [v (. manifest-name-cache pkg-dir)]
    (if v v nil)))

(fn flat-extension-output [src]
  "Match flat-layout extension sources: extensions/<kebab>/<rel>.fnl
   where <rel> is at the package root (not under src/, dist/, tests/,
   vendor/, .lrbuild/). Returns the workspace dist path or nil."
  (let [(pkg-dir rel) (string.match src "^(extensions/[^/]+)/(.+)%.fnl$")]
    (when (and pkg-dir
               (not (string.find rel "^src/"))
               (not (string.find rel "^dist/"))
               (not (string.find rel "^tests/"))
               (not (string.find rel "^vendor/"))
               (not (string.find rel "^%.lrbuild/")))
      (let [snake (read-manifest-name pkg-dir)]
        (when snake
          (.. pkg-dir "/dist/fen/extensions/" snake "/" rel ".lua"))))))

(fn workspace-output-path [src]
  (or (flat-extension-output src)
      (let [(pkg rel) (string.match src "^(.-)/src/(.*)%.fnl$")]
        (assert pkg (.. "cannot derive output path for " src))
        (.. pkg "/dist/" rel ".lua"))))

(fn strip-leading-dot [s]
  (or (string.match s "^%./(.*)") s))

(fn lrbuild-flat-output [src]
  "Flat extension source seen from within its own rock dir (cwd has
   manifest.fnl at root, sources at ./<rel>.fnl). Returns the .lrbuild path
   or nil if cwd is rock-shaped (no root manifest)."
  (when (file-exists? "manifest.fnl")
    (let [snake (read-manifest-name ".")
          rel (string.match src "^(.+)%.fnl$")]
      (when (and snake rel (not (string.match rel "^src/")))
        (.. ".lrbuild/extensions/" snake "/" rel ".lua")))))

(fn lrbuild-output-path [src]
  (let [src (strip-leading-dot src)]
    (or (lrbuild-flat-output src)
        (let [rel (string.match src "^src/fen/(.*)%.fnl$")]
          (assert rel (.. "cannot derive .lrbuild output path for " src))
          (.. ".lrbuild/" rel ".lua")))))

(fn compile-file [src output-path]
  (let [out (output-path src)
        compiled (fennel.compileString (read-all src) {:filename src})]
    (os.execute (.. "mkdir -p " (shell-quote (dirname out))))
    (write-all out compiled)))

(fn build-files [files output-path]
  (var ok? true)
  (each [_ src (ipairs files)]
    (let [(ok err) (pcall compile-file src output-path)]
      (when (not ok)
        (print (.. "FAIL: " src))
        (print err)
        (set ok? false))))
  ok?)

(fn worker-main [list-path lrbuild?]
  (os.exit (if (build-files (read-list list-path)
                            (if lrbuild? lrbuild-output-path workspace-output-path))
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
        self (or (. arg 0) "scripts/fennel-build.fnl")
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

;; Find both `src/`-tree sources (rock-shaped: core, util, fen, providers/*)
;; and flat-layout extension sources (manifest.fnl at the package root).
;; The path-routing logic in workspace-output-path decides where each lands.
(local workspace-find
  (.. "find packages extensions -name '*.fnl' -type f"
      " -not -path '*/dist/*'"
      " -not -path '*/tests/*'"
      " -not -path '*/vendor/*'"
      " -not -path '*/.lrbuild/*'"
      " | sort"))

;; Lrbuild runs from a rock package dir. Pick up flat sources at cwd root
;; OR src/-tree sources for rock-shaped packages; lrbuild-output-path
;; routes based on whether cwd has manifest.fnl.
(local lrbuild-find
  (.. "find . -type f -name '*.fnl'"
      " -not -path './tests/*'"
      " -not -path './vendor/*'"
      " -not -path './.lrbuild/*'"
      " -not -path './dist/*'"
      " | sort"))

(fn main []
  (when (= (. arg 1) :--worker)
    (worker-main (. arg 2) (= (. arg 3) :--lrbuild)))
  (let [lrbuild? (= (. arg 1) :--lrbuild)
        files (command-lines (if lrbuild? lrbuild-find workspace-find))]
    (when lrbuild?
      (os.execute "rm -rf .lrbuild"))
    (if (run-workers files (default-jobs) lrbuild?)
      (os.exit 0)
      (os.exit 1))))

(main)
