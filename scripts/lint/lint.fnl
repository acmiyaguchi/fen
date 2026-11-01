#!/usr/bin/env fennel
;; Static lint for fen's layering and hot-reload invariants (#676).
;;
;;   fennel scripts/lint/lint.fnl [--json] [--strict] [--quiet]
;;
;; Rules (scripts/lint/rules/*.fnl):
;;   layer/deps    cross-rock require not covered by rockspec dependencies
;;   reload/list   extension module missing from, or phantom in, reload-modules
;;   reload/state  module-level var/table mutated at call time in a reloadable module
;;   lint/waiver   a waiver without a reason
;;   lint/parse    a reloadable file that does not parse (reload/state cannot run)
;;   lint/manifest an extension manifest that does not evaluate
;;
;; Waive a finding with a trailing comment on its line, or a comment-only line
;; directly above it:
;;   ;; lint-allow <rule>: <reason>
;; Every waiver is reported (--quiet omits the list). Report-only by default;
;; --strict exits 1 on unwaived findings.

(local fennel (require :fennel))
(set fennel.path
     (.. fennel.path ";./scripts/?.fnl;./scripts/?/init.fnl"
         ";./packages/core/src/?.fnl;./packages/core/src/?/init.fnl"))

(local scanner (require :docs.scanner))
(local waiver (require :lint.waiver))
(local {: core-reloadable?} (require :fen.core.extensions.loader.reloadable))

(local RULES (icollect [_ name (ipairs [:layer :reload_list :reload_state])]
               (require (.. :lint.rules. name))))

(fn read-file [path]
  (let [f (io.open path :r)]
    (when f
      (let [data (f:read :*a)]
        (f:close)
        data))))

(fn command-lines [cmd]
  (let [p (assert (io.popen cmd :r))
        out (icollect [line (p:lines)] line)]
    (p:close)
    out))

;; ----- Facts --------------------------------------------------------------

(fn rockspec-of [dir]
  "{:name :deps} from the single *.rockspec in `dir`, or nil."
  (let [path (. (command-lines (.. "ls " dir "/*.rockspec 2>/dev/null")) 1)
        text (and path (read-file path))]
    (when text
      (let [block (or (string.match text "\ndependencies%s*=%s*(%b{})") "")]
        {:name (string.match text "package%s*=%s*\"([^\"]+)\"")
         :deps (icollect [dep (string.gmatch block "\"([%w_%-]+)")] dep)}))))

(fn rock-dir [modinfo]
  (if (= modinfo.scope :package) (.. "packages/" modinfo.pkg) modinfo.pkg))

(fn read-manifest [path]
  "(manifest nil) or ({} err) when the manifest does not evaluate to a table."
  (let [text (read-file path)
        (ok? v) (pcall fennel.eval (or text "") {:env {} :filename path})]
    (if (and ok? (= :table (type v))) (values v nil)
        (values {}
                (if ok? "manifest does not evaluate to a table" (tostring v))))))

(fn gather []
  (let [tree (scanner.scan-tree)
        rocks {}
        deps {}
        owners {}
        files []
        extensions {}]
    (each [_ f (ipairs tree.files)]
      (let [mi f.module-info
            dir (and mi (rock-dir mi))]
        (when (and dir (= nil (. rocks dir)))
          (tset rocks dir (or (rockspec-of dir) false))
          (let [r (. rocks dir)]
            (when r (tset deps r.name r.deps))))
        (let [rock (let [r (and dir (. rocks dir))]
                     (and r r.name))]
          (when (and mi rock) (tset owners mi.module rock))
          (when (and mi (= mi.scope :extension) (= nil (. extensions dir)))
            (let [mpath (.. dir "/manifest.fnl")]
              (let [(manifest err) (read-manifest mpath)]
                (tset extensions dir
                      {:root dir
                       :manifest-path mpath
                       : manifest
                       :manifest-error err
                       :modules []}))))
          (when (and mi (= mi.scope :extension))
            (table.insert (. extensions dir :modules)
                          {:module mi.module :path f.path}))
          (table.insert files
                        {:path f.path
                         : rock
                         :module (?. mi :module)
                         :scope (?. mi :scope)
                         :ext-root (and mi (= mi.scope :extension) dir)
                         :dependencies f.dependencies}))))
    (each [_ f (ipairs files)]
      (set f.source (read-file f.path))
      (set f.reloadable? (if (= f.scope :package) (core-reloadable? f.module)
                             (= f.scope :extension)
                             (let [m (. extensions f.ext-root :manifest)
                                   has? #(accumulate [hit false _ x (ipairs (or $1
                                                                                []))]
                                           (or hit (= x f.module)))]
                               (and (has? m.reload-modules)
                                    (not (has? m.reload-exclude))))
                             false)))
    {: files
     : owners
     : deps
     :extensions (let [xs (icollect [_ e (pairs extensions)] e)]
                   (table.sort xs #(< $1.root $2.root))
                   xs)}))

;; ----- Waivers ------------------------------------------------------------

(local line-cache {})

(fn lines-of [path]
  (when (= nil (. line-cache path))
    (tset line-cache path (icollect [l (string.gmatch (.. (or (read-file path)
                                                              "")
                                                          "\n")
                                                      "([^\n]*)\n")]
                            l)))
  (. line-cache path))

(fn waiver-for [finding]
  (waiver.for-line (lines-of finding.path) finding.line finding.rule))

;; ----- Output -------------------------------------------------------------

(fn json-str [s]
  (.. "\""
      (string.gsub (tostring s) "[%c\"\\]"
                   #(if (= $1 "\"") "\\\""
                        (= $1 "\\") "\\\\"
                        (string.format "\\u%04x" (string.byte $1)))) "\""))

(fn json-finding [f]
  (.. "{\"rule\":" (json-str f.rule) ",\"severity\":" (json-str f.severity)
      ",\"path\":" (json-str f.path) ",\"line\":" (or f.line 1) ",\"message\":"
      (json-str f.message) (if f.waived (.. ",\"waived\":" (json-str f.waived))
                              "") "}"))

(fn main [argv]
  (let [json? (accumulate [x false _ a (ipairs argv)] (or x (= a :--json)))
        strict? (accumulate [x false _ a (ipairs argv)] (or x (= a :--strict)))
        quiet? (accumulate [x false _ a (ipairs argv)] (or x (= a :--quiet)))
        facts (gather)
        all []]
    (each [_ rule (ipairs RULES)]
      (each [_ f (ipairs (rule.check facts))]
        (set f.severity :warning)
        (let [w (waiver-for f)]
          (if (= w :no-reason)
              (table.insert all
                            {:rule :lint/waiver
                             :severity :warning
                             :path f.path
                             :line f.line
                             :message (.. "waiver for " f.rule
                                          " needs a reason")})
              (set f.waived w)))
        (table.insert all f)))
    (table.sort all #(if (= $1.path $2.path) (< $1.line $2.line)
                         (< $1.path $2.path)))
    (let [open (icollect [_ f (ipairs all)] (when (not f.waived) f))
          waived (icollect [_ f (ipairs all)] (when f.waived f))]
      (if json?
          (print (.. "[" (table.concat (icollect [_ f (ipairs all)]
                                         (json-finding f))
                                       ",") "]"))
          (do
            (each [_ f (ipairs open)]
              (print (string.format "%s:%d: %s %s: %s" f.path f.line f.rule
                                    f.severity f.message)))
            (each [_ f (ipairs (if quiet? [] waived))]
              (print (string.format "%s:%d: %s waived: %s" f.path f.line f.rule
                                    f.waived)))
            (let [counts {}]
              (each [_ f (ipairs open)]
                (tset counts f.rule (+ 1 (or (. counts f.rule) 0))))
              (print (string.format "lint: %d finding(s), %d waived%s"
                                    (length open) (length waived)
                                    (let [parts (icollect [r n (pairs counts)]
                                                  (.. r "=" n))]
                                      (table.sort parts)
                                      (if (< 0 (length parts))
                                          (.. " (" (table.concat parts " ") ")")
                                          "")))))))
      (when (and strict? (< 0 (length open)))
        (os.exit 1)))))

(main arg)
