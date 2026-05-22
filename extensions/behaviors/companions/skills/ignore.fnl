;; Minimal .gitignore-compatible ignore-rule engine used by skill discovery.
;;
;; Reads `.gitignore` / `.ignore` / `.fdignore` files and answers "is this path
;; ignored against this rule chain?" The matcher implements a small subset of
;; the gitignore syntax that's load-bearing for skill discovery: glob `*`,
;; `**`, `?`, leading `!` for negation, trailing `/` for directory-only,
;; leading `/` for anchored-to-base rules. Last matching rule wins.
;;
;; Public surface (intentionally small):
;;   load-chain root  → rules collected along ancestors of `root`
;;   with-dir rules dir → rules ++ ignore files found in `dir`
;;   match? path is-dir? rules → true when `path` is currently ignored

(local path (require :fen.util.path))

(local M {})

(local trim (. (require :fen.util.text) :trim))

(fn read-lines [file-path]
  (let [out []
        f (io.open file-path :r)]
    (when f
      (each [line (f:lines)]
        (let [clean (string.gsub line "\r$" "")]
          (table.insert out clean)))
      (f:close))
    out))

(fn parse-line [line base-dir]
  (let [raw (trim line)]
    (when (and (not= raw "") (not (string.match raw "^#")))
      (var pat raw)
      (var negated? false)
      (when (= (string.sub pat 1 1) "!")
        (set negated? true)
        (set pat (string.sub pat 2)))
      (set pat (trim pat))
      (when (not= pat "")
        (var dir-only? false)
        (while (= (string.sub pat -1) "/")
          (set dir-only? true)
          (set pat (string.sub pat 1 -2)))
        (var anchored? false)
        (when (= (string.sub pat 1 1) "/")
          (set anchored? true)
          (set pat (string.sub pat 2)))
        (when (= (string.sub pat 1 2) "./")
          (set pat (string.sub pat 3)))
        (when (not= pat "")
          {:base-dir base-dir
           :pattern pat
           :negated? negated?
           :dir-only? dir-only?
           :anchored? anchored?
           :has-slash? (not= nil (string.find pat "/" 1 true))})))))

(fn add-file! [rules dir filename]
  (let [file-path (.. dir "/" filename)]
    (when (path.file-exists? file-path)
      (each [_ line (ipairs (read-lines file-path))]
        (let [rule (parse-line line dir)]
          (when rule (table.insert rules rule)))))))

(fn add-files! [rules dir]
  (add-file! rules dir ".gitignore")
  (add-file! rules dir ".ignore")
  (add-file! rules dir ".fdignore"))

(fn copy-rules [rules]
  (let [out []]
    (each [_ r (ipairs rules)] (table.insert out r))
    out))

;; @doc fen.extensions.skills.ignore.with-dir
;; kind: function
;; signature: (with-dir rules dir) -> [IgnoreRule]
;; summary: Return a copied ignore-rule chain extended with .gitignore, .ignore, and .fdignore files from one directory.
;; tags: skills ignore rules discovery
(fn M.with-dir [rules dir]
  "Return a fresh rule list = `rules` ++ ignore files found directly in `dir`."
  (let [out (copy-rules rules)]
    (add-files! out dir)
    out))

;; @doc fen.extensions.skills.ignore.load-chain
;; kind: function
;; signature: (load-chain root) -> [IgnoreRule]
;; summary: Collect ignore rules from ancestor directories root-to-leaf for skill discovery traversal.
;; tags: skills ignore rules discovery
(fn M.load-chain [root]
  "Collect ignore rules walking the ancestors of `root` root-to-leaf."
  (let [rules []]
    (each [_ dir (ipairs (path.ancestors-root-to-leaf root))]
      (add-files! rules dir))
    rules))

(fn relative-to [target base]
  (if (= target base) ""
      (= (string.sub target 1 (+ (length base) 1)) (.. base "/"))
      (string.sub target (+ (length base) 2))
      nil))

(fn lua-pattern-escape [c]
  (if (string.find "^$()%.[]*+-?%%" c 1 true)
      (.. "%" c)
      c))

(fn glob-to-lua-pattern [glob]
  (let [out []]
    (var i 1)
    (while (<= i (length glob))
      (let [c (string.sub glob i i)
            n (string.sub glob (+ i 1) (+ i 1))]
        (if (and (= c "*") (= n "*"))
            (do (table.insert out ".*")
                (set i (+ i 2)))
            (= c "*")
            (do (table.insert out "[^/]*")
                (set i (+ i 1)))
            (= c "?")
            (do (table.insert out "[^/]")
                (set i (+ i 1)))
            (do (table.insert out (lua-pattern-escape c))
                (set i (+ i 1))))))
    (.. "^" (table.concat out "") "$")))

(fn glob-match? [s glob]
  (not= nil (string.match s (glob-to-lua-pattern glob))))

(fn component-matches? [rel glob]
  (var matched? false)
  (each [part (string.gmatch rel "[^/]+")]
    (when (glob-match? part glob)
      (set matched? true)))
  matched?)

(fn rule-matches? [rule target is-dir?]
  (let [rel (relative-to target rule.base-dir)]
    (if (or (not rel) (= rel ""))
        false
        (and rule.dir-only? (not is-dir?))
        false
        (if (and (not rule.anchored?) (not rule.has-slash?))
            (component-matches? rel rule.pattern)
            (or (glob-match? rel rule.pattern)
                (and rule.dir-only?
                     (let [prefix (.. rule.pattern "/")]
                       (= (string.sub rel 1 (length prefix)) prefix))))))))

;; @doc fen.extensions.skills.ignore.match?
;; kind: function
;; signature: (match? target is-dir? rules) -> boolean
;; summary: Decide whether a path is ignored by the rule chain, with later negated or matching rules taking precedence.
;; tags: skills ignore rules match
(fn M.match? [target is-dir? rules]
  "Last matching ignore rule wins. Negated rules re-include the path. The
   caller is responsible for not descending into already-skipped directories."
  (var skip? false)
  (each [_ rule (ipairs rules)]
    (when (rule-matches? rule target is-dir?)
      (set skip? (not rule.negated?))))
  skip?)

M
