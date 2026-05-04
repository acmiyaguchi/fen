;; Lightweight Fennel-source scanner shared by gen-docs and doc-coverage.
;;
;; The scanner is text-based on purpose: it doesn't execute application
;; code, it just reads forms structurally. Coverage of dynamic registration
;; patterns is best-effort.
;;
;; Scanned shapes:
;;   - exported functions   (fn M.foo ...) / (set M.foo ...) / trailing
;;                          export table {: foo : bar}
;;   - register sites       (api.register :kind {...}) — :name extracted
;;                          when it's a literal keyword/string
;;   - emitted events       (...emit {:type :foo ...}) across emit verbs
;;   - inline doc blocks    ;; @doc <id>  /  ;; key: value
;;
;; Module-id derivation
;;   packages/<pkg>/src/<rel>.fnl    -> dotted <rel> (drop trailing .init)
;;   extensions/<dir>/<rel>.fnl      -> fen.extensions.<snake>(.<rel>)
;;     where <snake> comes from extensions/<dir>/manifest.fnl :name

(local M {})

(local SOURCE-FIND
  (.. "find packages extensions -name '*.fnl' -type f"
      " -not -path '*/dist/*'"
      " -not -path '*/tests/*'"
      " -not -path '*/vendor/*'"
      " -not -path '*/.lrbuild/*'"
      " -not -name 'manifest.fnl'"
      " | sort"))

(fn read-file [path]
  (let [f (assert (io.open path :r))
        data (f:read :*a)]
    (f:close)
    data))

(fn command-lines [cmd]
  (let [p (assert (io.popen cmd :r))
        out []]
    (each [line (p:lines)]
      (table.insert out line))
    (p:close)
    out))

(fn split-lines [text]
  (let [out []]
    (each [line (string.gmatch (.. text "\n") "([^\n]*)\n")]
      (table.insert out line))
    out))

;; Manifest-name cache keyed by extension package dir.
(local manifest-name-cache {})

(fn parse-manifest-name [text]
  (or (string.match text ":name%s+:([%w_%-]+)")
      (string.match text ":name%s+\"([^\"]+)\"")))

(fn read-manifest-name [pkg-dir]
  (when (= nil (. manifest-name-cache pkg-dir))
    (let [path (.. pkg-dir "/manifest.fnl")
          f (io.open path :r)]
      (if f
          (let [data (f:read :*a)]
            (f:close)
            (tset manifest-name-cache pkg-dir
                  (or (parse-manifest-name data) false)))
          (tset manifest-name-cache pkg-dir false))))
  (let [v (. manifest-name-cache pkg-dir)]
    (if v v nil)))

(fn module-from-path [path]
  "Return {:module \"fen.core...\" :pkg \"core\"} or nil for unknown layouts."
  (let [(pkg rel) (string.match path "^packages/([^/]+)/src/(.+)%.fnl$")]
    (if (and pkg rel)
        (let [dotted (string.gsub rel "/" ".")
              cleaned (or (string.match dotted "^(.+)%.init$") dotted)]
          {:module cleaned :pkg pkg :scope :package})
        (let [(ext-dir rel) (string.match path "^extensions/([^/]+)/(.+)%.fnl$")]
          (when (and ext-dir rel)
            (let [snake (read-manifest-name (.. "extensions/" ext-dir))
                  rel-noinit (or (string.match rel "^(.+)/init$") rel)
                  dotted (string.gsub rel-noinit "/" ".")]
              (when snake
                (let [base (.. "fen.extensions." snake)
                      module (if (= dotted :init) base (.. base "." dotted))]
                  {:module module :pkg ext-dir :scope :extension}))))))))

;; ----- Doc-block parsing ---------------------------------------------------

(fn parse-doc-line [s]
  "Parse `;; key: value` into [key value], or nil."
  (let [(k v) (string.match s "^;;%s+([%w%-_]+)%s*:%s*(.*)$")]
    (when (and k (not (= k :doc)))
      (values k (or v "")))))

(fn parse-tags [csv]
  (let [out []]
    (each [t (string.gmatch (or csv "") "[^,%s]+")]
      (table.insert out t))
    out))

(fn parse-doc-block [lines start-idx]
  "Parse a ;; @doc block beginning at lines[start-idx]. Returns
   {:id :kind :signature :summary :tags :line :end-line :see-also} where
   :line is start-idx (1-based) and :end-line is the last consumed comment."
  (let [head (. lines start-idx)
        id (string.match head "^;;%s+@doc%s+(%S+)")]
    (when id
      (let [doc {:id id
                 :line start-idx
                 :end-line start-idx
                 :tags []}]
        (var i (+ start-idx 1))
        (var stop? false)
        (while (and (not stop?) (<= i (# lines)))
          (let [line (. lines i)]
            (if (string.match line "^%s*;;")
                (do
                  (let [(k v) (parse-doc-line line)]
                    (when k
                      (if (= k :tags)
                          (tset doc :tags (parse-tags v))
                          (= k :see-also)
                          (tset doc :see-also (parse-tags v))
                          (tset doc k v))))
                  (set doc.end-line i)
                  (set i (+ i 1)))
                (set stop? true))))
        doc))))

(fn collect-doc-blocks [lines]
  "Walk lines for `;; @doc ...` openers; return list of parsed blocks
   in source order."
  (let [out []]
    (var i 1)
    (while (<= i (# lines))
      (let [line (. lines i)]
        (if (string.match line "^%s*;;%s+@doc%s+%S+")
            (let [doc (parse-doc-block lines i)]
              (table.insert out doc)
              (set i (+ doc.end-line 1)))
            (set i (+ i 1)))))
    out))

(fn doc-block-for-line [docs target-line]
  "Find the @doc block whose end-line is target-line - 1
   (i.e. the comment block immediately above the form)."
  (var found nil)
  (each [_ doc (ipairs docs)]
    (when (= doc.end-line (- target-line 1))
      (set found doc)))
  found)

(fn doc-block-by-id [docs id]
  "Find the @doc block whose declared id exactly matches. Useful when a
   constructor/constant is exported through a trailing table and the
   block sits at the definition site, not above the export form."
  (var found nil)
  (each [_ doc (ipairs docs)]
    (when (= doc.id id)
      (set found doc)))
  found)

;; ----- Export detection ----------------------------------------------------

(fn scan-fn-exports [lines]
  "Detect (fn M.foo ...) and (set M.foo ...) exports, classified as
   :function (callable) or :data (table/value re-export). A
   `(set M.foo (fn ...))` counts as :function; otherwise set-exports
   are :data."
  (let [out []]
    (each [i line (ipairs lines)]
      (let [fn-name (string.match line "^%(fn%s+M%.([%w%-_!?]+)")
            set-name (string.match line "^%(set%s+M%.([%w%-_!?]+)")]
        (if fn-name
            (let [sig (string.match line "^%(fn%s+M%.[^%s]+%s+(%[[^%]]*%])")]
              (table.insert out {:name fn-name :line i :signature sig
                                 :kind :function}))
            set-name
            (let [fn-rhs? (string.match line
                            "^%(set%s+M%.[^%s]+%s+%(fn[%s%[]")
                  kind (if fn-rhs? :function :data)]
              (table.insert out {:name set-name :line i :kind kind})))))
    out))

(fn scan-trailing-exports [text]
  "Extract names exported via a trailing `{: foo : bar}` literal returned
   from the module body. Conservative: looks at the LAST top-level form
   beginning with `{:` or `{ :` at column 0."
  (let [last-open (string.find text "\n({[%s\n]*:[^}]+})%s*$")
        out []]
    (when last-open
      (let [body (string.match text "\n({[%s\n]*:[^}]+})%s*$")]
        (when body
          ;; Shorthand `: name` -> exports as <name>.
          (each [name (string.gmatch body ":%s*([%w%-_!?]+)")]
            (table.insert out {:name name :shorthand? true})))))
    out))

(fn classify-trailing-name [text name]
  "Look back into the file to see how `name` was bound. Returns
   :function | :data | :unknown."
  (let [ident (string.gsub name "[%-]" "%%-")
        ident (string.gsub ident "[!?]" "%%%1")
        fn-pat (.. "%(fn%s+" ident "%s*%[")
        local-fn-pat (.. "%(local%s+" ident "%s+%(fn[%s%[]")
        local-pat (.. "%(local%s+" ident "%s")]
    (if (string.find text fn-pat) :function
        (string.find text local-fn-pat) :function
        (string.find text local-pat) :data
        :unknown)))

(fn scan-trailing-export-form [text lines]
  "Robust trailing-table walker: locate the final {...} form that ends
   the file and parse top-level keys."
  ;; Scan from the end backward to find the start of the final balanced
  ;; `{...}` (or `(... )`) form. We support `{:foo bar : baz ...}` and
  ;; `(values ...)`-style returns are ignored (only literal tables count).
  (let [out []
        n (# text)]
    ;; Walk forward maintaining depth. Track every `{` as a candidate
    ;; opening for the trailing form; remember the last one whose match
    ;; closes at end-of-text (modulo trailing whitespace).
    (var i 1)
    (var depth 0)
    (var last-table-start nil)
    (var last-table-end nil)
    (var in-string false)
    (var string-char nil)
    (var in-line-comment false)
    (while (<= i n)
      (let [ch (string.sub text i i)]
        (if in-line-comment
            (when (= ch "\n") (set in-line-comment false))
            in-string
            (do
              (when (= ch "\\")
                (set i (+ i 1)))
              (when (= ch string-char)
                (set in-string false)
                (set string-char nil)))
            (= ch ";")
            (set in-line-comment true)
            (= ch "\"")
            (do (set in-string true) (set string-char "\""))
            (or (= ch "(") (= ch "[") (= ch "{"))
            (do
              (when (and (= ch "{") (= depth 0))
                (set last-table-start i))
              (set depth (+ depth 1)))
            (or (= ch ")") (= ch "]") (= ch "}"))
            (do
              (set depth (- depth 1))
              (when (and (= ch "}") (= depth 0))
                (set last-table-end i))))
        (set i (+ i 1))))
    (when (and last-table-start last-table-end)
      ;; Ensure this table is the trailing form: only whitespace/comments
      ;; allowed after `last-table-end` until EOF.
      (let [tail (string.sub text (+ last-table-end 1))
            tail-trimmed (string.gsub tail "%s+" "")
            comment-stripped (string.gsub tail-trimmed ";[^\n]*" "")]
        (when (= comment-stripped "")
          (let [body (string.sub text last-table-start last-table-end)
                ;; Compute starting line of body for source-line attribution.
                preamble (string.sub text 1 (- last-table-start 1))
                start-line (+ 1 (select 2 (string.gsub preamble "\n" "")))]
            ;; Walk body for top-level `: name` shorthand and `:name expr`.
            (var j 2)  ; skip leading `{`
            (var bdepth 1)
            (var b-in-string false)
            (var b-string-char nil)
            (var b-in-comment false)
            (let [bn (# body)]
              (while (<= j bn)
                (let [bc (string.sub body j j)]
                  (if b-in-comment
                      (when (= bc "\n") (set b-in-comment false))
                      b-in-string
                      (do
                        (when (= bc "\\") (set j (+ j 1)))
                        (when (= bc b-string-char)
                          (set b-in-string false)
                          (set b-string-char nil)))
                      (= bc ";")
                      (set b-in-comment true)
                      (= bc "\"")
                      (do (set b-in-string true) (set b-string-char "\""))
                      (or (= bc "(") (= bc "[") (= bc "{"))
                      (set bdepth (+ bdepth 1))
                      (or (= bc ")") (= bc "]") (= bc "}"))
                      (set bdepth (- bdepth 1))
                      (and (= bdepth 1) (= bc ":"))
                      ;; Only top-level `:` is a key. Allow optional
                      ;; whitespace before the name (shorthand `:  foo`
                      ;; never appears in practice but consistent forms
                      ;; like `: make-agent` always do).
                      (let [rest (string.sub body (+ j 1))
                            (lead sname after) (string.match rest "^(%s*)([%w%-_!?]+)(.*)$")]
                        (when sname
                          (let [trimmed (string.match (or after "") "^%s*(.-)%s*$")
                                next-ch (string.sub trimmed 1 1)
                                shorthand? (or (= next-ch ":") (= next-ch "}") (= next-ch ""))
                                kind (classify-trailing-name text sname)]
                            (table.insert out {:name sname
                                               :shorthand? shorthand?
                                               :line start-line
                                               :kind kind}))
                          (set j (+ j (# (or lead "")) (# sname))))))
                  (set j (+ j 1))))))))) ; close while/let/let
    out))

(fn merge-exports [fn-exports trailing-exports]
  "Combine fn-export and trailing-export records, deduped by name."
  (let [seen {}
        out []]
    (each [_ e (ipairs fn-exports)]
      (when (not (. seen e.name))
        (tset seen e.name true)
        (table.insert out e)))
    (each [_ e (ipairs trailing-exports)]
      (when (not (. seen e.name))
        (tset seen e.name true)
        (table.insert out e)))
    out))

;; ----- Register-site detection --------------------------------------------

(fn line-of [text byte-pos]
  (+ 1 (select 2 (string.gsub (string.sub text 1 byte-pos) "\n" ""))))

(fn strip-non-code [text]
  "Replace string-literal contents and line comments with spaces while
   preserving byte offsets and newlines. The result is safe for plain
   regex find against code positions."
  (let [chars []
        n (# text)]
    (var i 1)
    (var in-string false)
    (var string-char nil)
    (var in-comment false)
    (var skip-next false)
    (while (<= i n)
      (let [ch (string.sub text i i)]
        (if skip-next
            (do (set skip-next false)
                (table.insert chars (if (= ch "\n") "\n" " ")))
            (= ch "\n")
            (do (table.insert chars "\n")
                (when in-comment (set in-comment false)))
            in-comment
            (table.insert chars " ")
            in-string
            (do
              (table.insert chars " ")
              (if (= ch "\\")
                  (set skip-next true)
                  (= ch string-char)
                  (do (set in-string false)
                      (set string-char nil))))
            (= ch ";")
            (do (set in-comment true) (table.insert chars " "))
            (= ch "\"")
            (do (set in-string true) (set string-char "\"")
                (table.insert chars " "))
            (table.insert chars ch)))
      (set i (+ i 1)))
    (table.concat chars)))

(fn extract-spec-field [body field-pat]
  "Pull a literal field value from the spec table body. Supports
   :keyword, \"string\", and ignores complex expressions."
  (let [(_ _ kw) (string.find body (.. field-pat ":([%w%-_!?]+)"))
        (_ _ str) (string.find body (.. field-pat "\"([^\"]*)\""))]
    (or kw str)))

(fn scan-register-sites [text]
  "Find every `(api.register :kind {...})` call. Returns
   [{:kind :name :description :path :line}]."
  (let [code (strip-non-code text)
        out []
        n (# code)]
    (var pos 1)
    (while pos
      (let [(s e kind) (string.find code "%(api%.register%s+:([%w%-_]+)" pos)]
        (if (not s)
            (set pos nil)
            (do
              ;; Walk forward through `code` (string-stripped) to find
              ;; the spec-table extent, then read the matching slice from
              ;; `text` so descriptions/string-typed values come back
              ;; with their original contents.
              (var i e)
              (var depth 1)  ; inside the (api.register ...
              (var spec-start nil)
              (var spec-end nil)
              (var sd 0)
              (var found-spec? false)
              (while (and (<= i n) (= depth 1))
                (set i (+ i 1))
                (let [ch (string.sub code i i)]
                  (if (and (not found-spec?) (= ch "{"))
                      (do (set spec-start i) (set sd 1)
                          (set found-spec? true))
                      (and found-spec? (not spec-end)
                           (or (= ch "{") (= ch "(") (= ch "[")))
                      (set sd (+ sd 1))
                      (and found-spec? (not spec-end)
                           (or (= ch "}") (= ch ")") (= ch "]")))
                      (do (set sd (- sd 1))
                          (when (= sd 0) (set spec-end i)))
                      (= ch "(") (set depth (+ depth 1))
                      (= ch ")") (set depth (- depth 1)))))
              (let [body (if (and spec-start spec-end)
                             (string.sub text spec-start spec-end)
                             "")
                    code-body (if (and spec-start spec-end)
                                  (string.sub code spec-start spec-end)
                                  "")
                    name (or (extract-spec-field body ":name%s+")
                             (extract-spec-field code-body ":name%s+"))
                    description (extract-spec-field body ":description%s+")
                    has-description? (not= nil
                                       (string.find code-body
                                         "[%s{]:description[%s}]"))]
                (table.insert out {:kind kind
                                   :name name
                                   :description description
                                   :has-description? has-description?
                                   :line (line-of code s)}))
              (set pos (+ e 1))))))
    out))

;; ----- Emit-call detection -------------------------------------------------

(local EMIT-CALL-PATTERNS
  ["%(events%.emit%s"
   "%(extensions%.emit%s"
   "%(api%.emit%s"
   "%(M%.emit%s"
   "%(emit%s+agent"
   "%(emit%s+{"])

(fn scan-emit-types [text]
  "Find every `(.../emit ... {:type :foo ...})` and capture :foo. Returns
   [{:type :foo :line N}]."
  (let [code (strip-non-code text)
        out []
        n (# code)]
    (each [_ pat (ipairs EMIT-CALL-PATTERNS)]
      (var pos 1)
      (while pos
        (let [(s e) (string.find code pat pos)]
          (if (not s)
              (set pos nil)
              (do
                ;; Find next :type :foo within reasonable lookahead and
                ;; before the matching close-paren of this call.
                (var i e)
                (var depth 1)
                (var hit nil)
                (while (and (<= i n) (> depth 0) (not hit))
                  (set i (+ i 1))
                  (let [ch (string.sub code i i)]
                    (if (or (= ch "(") (= ch "[") (= ch "{"))
                        (set depth (+ depth 1))
                        (or (= ch ")") (= ch "]") (= ch "}"))
                        (set depth (- depth 1))))
                  (when (and (> depth 0) (not hit))
                    (let [(_ _ t) (string.find code "^:type%s+:([%w%-_]+)" i)]
                      (when t (set hit t)))))
                (when hit
                  (table.insert out {:type hit :line (line-of code s)}))
                (set pos (+ e 1)))))))
    out))

;; ----- Per-file scan -------------------------------------------------------

(fn scan-file [path]
  "Return a record describing the public surface, register sites, and
   events of one Fennel source file."
  (let [text (read-file path)
        lines (split-lines text)
        modinfo (module-from-path path)
        docs (collect-doc-blocks lines)
        fn-exports (scan-fn-exports lines)
        trailing (scan-trailing-export-form text lines)
        merged (merge-exports fn-exports trailing)
        register-sites (scan-register-sites text)
        emit-types (scan-emit-types text)]
    (each [_ e (ipairs merged)]
      (when modinfo
        (tset e :id (.. modinfo.module "." e.name))
        (tset e :module modinfo.module))
      (tset e :path path)
      (tset e :doc (or (and e.id (doc-block-by-id docs e.id))
                       (and e.line (doc-block-for-line docs e.line)))))
    {:path path
     :module-info modinfo
     :doc-blocks docs
     :exports merged
     :register-sites register-sites
     :emit-types emit-types}))

(fn M.scan-tree []
  "Scan every Fennel source under packages/ and extensions/. Returns
   {:files [scan-result] :sources [paths]}."
  (let [paths (command-lines SOURCE-FIND)
        files []]
    (each [_ p (ipairs paths)]
      (table.insert files (scan-file p)))
    {:files files :sources paths}))

(fn M.aggregate [tree]
  "Roll the per-file scans into top-level inventories."
  (let [exports []
        register-sites []
        emit-types {}
        doc-blocks []]
    (each [_ file (ipairs tree.files)]
      (each [_ e (ipairs file.exports)]
        (table.insert exports e))
      (each [_ r (ipairs file.register-sites)]
        (tset r :path file.path)
        (table.insert register-sites r))
      (each [_ ev (ipairs file.emit-types)]
        (let [bucket (or (. emit-types ev.type) [])]
          (table.insert bucket {:path file.path :line ev.line})
          (tset emit-types ev.type bucket)))
      (each [_ d (ipairs file.doc-blocks)]
        (tset d :path file.path)
        (table.insert doc-blocks d)))
    {:exports exports
     :register-sites register-sites
     :emit-types emit-types
     :doc-blocks doc-blocks}))

(fn M.read-contracts []
  "Load fen.core.docs.contracts. Caller must have arranged fennel.path
   so the require resolves."
  (require :fen.core.docs.contracts))

(set M.module-from-path module-from-path)
(set M.scan-file scan-file)
(set M.read-file read-file)
(set M.split-lines split-lines)

M
