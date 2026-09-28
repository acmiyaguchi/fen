#!/usr/bin/env fennel
;; Check or fix Fennel formatting with the pinned fnlfmt in scripts/format/vendor.
;;
;;   check.fnl [--fix] FILE...          explicit paths, relative to the cwd
;;   check.fnl [--fix] --changed BASE   tracked .fnl files changed in the worktree
;;                                      since merge-base(BASE, HEAD), plus untracked
;;   check.fnl --staged                 index content of staged .fnl files
;;
;; One Fennel process formats every selected file. Existing files are
;; grandfathered: the git selectors pick only changed paths, never the whole tree.
;; Fix mode repeats fnlfmt to a fixed point (at most five passes, failing on a
;; cycle) and writes a file only after convergence, so a later check never
;; demands a second --fix. Check mode needs one pass: any change is a failure.
;; --staged never rewrites the index; fix the worktree file and re-add it.
(local fennel (require :fennel))
(local here (or (string.match (. arg 0) "^(.*)/[^/]*$") "."))
(set fennel.path (.. here "/vendor/?.fnl;" fennel.path))
(local formatter (require :fnlfmt))

(local usage
       "usage: check.fnl [--fix] (--changed BASE | FILE...) | check.fnl --staged")

(local vendor-exclude "':(top,exclude)scripts/format/vendor/**'")

(fn fail [msg]
  (error msg 0))

(fn read-all [path]
  (let [f (assert (io.open path :rb))
        text (f:read :*a)]
    (f:close)
    text))

(fn write-all [path text]
  (let [f (assert (io.open path :wb))]
    (f:write text)
    (f:close)))

(fn shell-quote [s]
  (.. "'" (string.gsub s "'" "'\\''") "'"))

(fn command-output [cmd]
  (let [p (assert (io.popen cmd :r))
        output (p:read :*a)
        ok? (p:close)]
    (when (not ok?) (fail (.. "command failed: " cmd)))
    output))

(fn git-top []
  (pick-values 1 (string.gsub (command-output "git rev-parse --show-toplevel")
                              "\n$" "")))

;; Git selectors run from the top level, so they work from any subdirectory
;; and yield top-relative paths; `display` keeps messages short.
(fn git-paths [top args]
  (let [files []]
    (each [path (string.gmatch (command-output (.. "git -C " (shell-quote top)
                                                   " " args " -z -- "
                                                   "':(top)*.fnl' "
                                                   vendor-exclude))
                               "([^%z]+)")]
      (table.insert files {:path (.. top "/" path) :display path}))
    files))

(fn changed-paths [top base]
  (let [files (git-paths top
                         (.. "diff --name-only --diff-filter=ACMR --merge-base "
                             (shell-quote base)))]
    (each [_ file (ipairs (git-paths top "ls-files --others --exclude-standard"))]
      (table.insert files file))
    files))

(fn preserve-shebang [original formatted]
  ;; fnlfmt rewrites a leading `#!` as `;;`, keeping any trailing `\r`.
  (let [shebang (string.match original "^(#![^\n]*)")]
    (if shebang
        (do
          (assert (= (string.match formatted "^([^\n]*)")
                     (.. ";;" (string.sub shebang 3)))
                  "fnlfmt changed a shebang unexpectedly")
          (string.gsub formatted "^[^\n]*" (fn [] shebang) 1))
        formatted)))

(fn fixed-point [original until-stable?]
  (let [tmp (os.tmpname)
        (ok? result) (pcall (fn []
                              (write-all tmp original)
                              (let [seen {original true}]
                                (var result nil)
                                (var pass 0)
                                (while (and (< pass 5) (not result))
                                  (set pass (+ pass 1))
                                  (let [formatted (preserve-shebang original
                                                                    (formatter.format-file tmp
                                                                                           {}))
                                        current (read-all tmp)]
                                    (if (= current formatted)
                                        (set result formatted)
                                        (not until-stable?)
                                        (set result formatted)
                                        (do
                                          (assert (not (. seen formatted))
                                                  "fnlfmt formatting cycle")
                                          (tset seen formatted true)
                                          (write-all tmp formatted)))))
                                (assert result
                                        "fnlfmt did not converge in 5 passes"))))]
    (os.remove tmp)
    (assert ok? result)
    result))

(fn check-one [{: path : display : staged} fix?]
  (let [original (if staged
                     (command-output (.. "git show " (shell-quote staged)))
                     (read-all path))
        formatted (fixed-point original fix?)]
    (if (= original formatted)
        true
        fix?
        (do
          (write-all path formatted)
          (print (.. "Formatted: " display))
          true)
        (do
          (io.stderr:write (.. "Not formatted: " display "\n"))
          false))))

(fn parse-args [argv]
  (let [fix? (= (. argv 1) :--fix)
        rest (if fix? [(select 2 (table.unpack argv))] argv)
        mode (. rest 1)]
    (if (= mode :--staged)
        (do
          (when (or fix? (not= 1 (length rest)))
            (fail (.. "--staged cannot be combined with --fix or paths\n" usage)))
          {:selector :staged})
        (= mode :--changed)
        (do
          (when (not= 2 (length rest)) (fail usage))
          {:selector :changed : fix? :base (. rest 2)})
        (do
          (when (= 0 (length rest)) (fail usage))
          (each [_ path (ipairs rest)]
            (when (= "-" (string.sub path 1 1))
              (fail (.. "unknown option " path "\n" usage))))
          {:selector :files : fix? :paths rest}))))

(fn select-files [{: selector : base : paths}]
  (case selector
    :staged (let [top (git-top)]
              (icollect [_ file (ipairs (git-paths top
                                                   "diff --cached --name-only --diff-filter=ACMR"))]
                (doto file
                  (tset :staged (.. ":" file.display)))))
    :changed (changed-paths (git-top) base)
    :files (icollect [_ path (ipairs paths)]
             {: path :display path})))

(fn main []
  (let [(selected? opts files) (pcall #(let [opts (parse-args arg)]
                                         (values opts (select-files opts))))]
    (when (not selected?)
      (io.stderr:write (.. "format: " (tostring opts) "\n"))
      (os.exit 2))
    (var ok? true)
    (each [_ file (ipairs files)]
      (let [(success result) (pcall check-one file opts.fix?)]
        (if (not success)
            (do
              (io.stderr:write (.. "format: " file.display ": "
                                   (tostring result) "\n"))
              (set ok? false))
            (not result)
            (set ok? false))))
    (when (not ok?) (os.exit 1))))

(main)
