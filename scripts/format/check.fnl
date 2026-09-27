#!/usr/bin/env fennel
;; Run pinned fnlfmt once per invocation, not once per file. Existing files are
;; intentionally grandfathered: pre-commit/CI check only staged/changed paths.
(local fennel (require :fennel))
(set fennel.path (.. "./scripts/format/vendor/?.fnl;" fennel.path))
(local formatter (require :fnlfmt))

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
    (assert ok? (.. "command failed: " cmd))
    output))

(fn nul-paths [cmd]
  (let [files []]
    (each [path (string.gmatch (command-output cmd) "([^%z]+)")]
      (table.insert files path))
    files))

(fn preserve-shebang [original formatted]
  (let [shebang (string.match original "^(#![^\r\n]*)")]
    (if shebang
        (do
          (assert (= (string.match formatted "^([^\n]*)")
                     (.. ";;" (string.sub shebang 3)))
                  "fnlfmt changed a shebang unexpectedly")
          (string.gsub formatted "^[^\n]*" (fn [] shebang) 1))
        formatted)))

;; Check mode needs only one pass: any change already means failure. Fix mode
;; repeats until stable so a subsequent check never demands a second --fix.
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

(fn check-one [path staged? fix?]
  (let [original (if staged?
                     (command-output (.. "git show "
                                         (shell-quote (.. ":" path))))
                     (read-all path))
        formatted (fixed-point original fix?)]
    (if (= original formatted)
        true
        (if fix?
            (do
              (write-all path formatted)
              (print (.. "Formatted: " path))
              true)
            (do
              (io.stderr:write (.. "Not formatted: " path "\n"))
              false)))))

(fn main []
  (let [mode (or (. arg 1) :--staged)
        staged? (= mode :--staged)
        fix? (= mode :--fix)
        paths (if staged?
                  (nul-paths "git diff --cached --name-only --diff-filter=ACMR -z -- '*.fnl' ':(exclude)scripts/format/vendor/**'")
                  (= mode :--changed)
                  (let [base (assert (. arg 2) "usage: --changed BASE")]
                    (nul-paths (.. "git diff --name-only --diff-filter=ACMR -z "
                                   (shell-quote (.. base "...HEAD"))
                                   " -- '*.fnl' ':(exclude)scripts/format/vendor/**'")))
                  (or (= mode :--check) fix?)
                  (let [files []]
                    (for [i 2 (length arg)]
                      (table.insert files (. arg i)))
                    files)
                  (error "usage: check.fnl --staged | --changed BASE | --check FILE... | --fix FILE..."))]
    (var ok? true)
    (each [_ path (ipairs paths)]
      (let [(success result) (pcall check-one path staged? fix?)]
        (if (not success)
            (do
              (io.stderr:write (.. "format: " path ": " (tostring result) "\n"))
              (set ok? false))
            (not result)
            (set ok? false))))
    (when (not ok?) (os.exit 1))))

(main)
