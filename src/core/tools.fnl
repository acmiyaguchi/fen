;; Tool registry and executor.
;;
;; Mirrors pi-mono's split:
;;   - `Tool`        (canonical, provider-agnostic): {name, description, parameters}
;;   - `AgentTool`   (pi-mono `packages/agent/src/types.ts:308`): adds
;;                   {label, execute}. We skip prepareArguments / executionMode /
;;                   signal / onUpdate because there's no consumer for them yet.
;;   - `AgentToolResult`: {content: [TextContent], is-error?, details?}
;;
;; The registry is an array of AgentTool, not a name-keyed map. Order matters
;; for things like UI display; lookup is by linear scan (we have a handful of
;; tools, this is fine).
;;
;; Tool execute receives a *parsed* arguments table — the provider has already
;; JSON-decoded the wire-level argument string before constructing the
;; canonical ToolCall block.
;;
;; POSIX-only stance: grep/find shell out to system grep(1)/find(1); we don't
;; require ripgrep/fd. read has no image base64 / syntax highlighting; edit
;; is exact-match only (no fuzzy fallback or unified-diff output). See
;; CLAUDE.md's "Conventions / gotchas" section.

(local types (require :core.types))

(fn agent-result [content is-error? details]
  (let [r {:content content :is-error? (or is-error? false)}]
    (when (not= details nil) (set r.details details))
    r))

(fn ok [text]
  (agent-result [(types.text-block (or text ""))] false nil))

(fn err [message]
  (agent-result [(types.text-block (.. "error: " message))] true nil))

(fn shellquote [s]
  (.. "'" (string.gsub s "'" "'\\''") "'"))

(fn int-arg [v default]
  "Normalize integer-ish tool args. Some providers/model calls pass JSON
   integers through as floats (e.g. 200.0); shell utilities like head(1) and
   grep(1) reject those when they require integer arguments. Non-numeric nil
   falls back to `default`."
  (let [n (tonumber v)]
    (if n (math.floor n) default)))

;; ----------------------------------------------------------------
;; Built-in tool implementations
;; ----------------------------------------------------------------

(fn run-bash [{: cmd : timeout}]
  (if (or (not cmd) (= cmd ""))
      (err "missing 'cmd'")
      (let [timeout-int (int-arg timeout nil)
            full-cmd (if (and timeout-int (> timeout-int 0))
                         (.. "timeout " (tostring timeout-int) "s " cmd)
                         cmd)
            pipe (io.popen (.. full-cmd " 2>&1") :r)]
        (if (not pipe) (err "io.popen failed")
            (let [out (pipe:read :*a)
                  (_ _ code) (pipe:close)]
              (ok (.. (or out "") "\n[exit " (tostring (or code 0)) "]")))))))

(fn run-read [{: path : offset : limit}]
  (if (or (not path) (= path ""))
      (err "missing 'path'")
      (let [(f open-err) (io.open path :r)]
        (if (not f) (err open-err)
            (if (and (not offset) (not limit))
                ;; Default: full slurp, preserves byte-exact content.
                (let [content (f:read :*a)]
                  (f:close)
                  (ok content))
                ;; Slice: f:lines drops the trailing newline; we re-join with
                ;; "\n" without re-adding one at the end.
                (let [start (int-arg offset 1)
                      take (or (int-arg limit nil) math.huge)
                      lines []]
                  (var n 0)
                  (each [line (f:lines)]
                    (set n (+ n 1))
                    (when (and (>= n start) (< (length lines) take))
                      (table.insert lines line)))
                  (f:close)
                  (ok (table.concat lines "\n"))))))))

(fn run-write [{: path : content}]
  (if (or (not path) (= path ""))
      (err "missing 'path'")
      (do
        ;; mkdir -p the parent so the model doesn't need a separate bash call.
        (let [parent (string.match path "^(.*)/[^/]+$")]
          (when parent
            (os.execute (.. "mkdir -p " (shellquote parent)))))
        (let [(f open-err) (io.open path :w)]
          (if (not f) (err open-err)
              (do (f:write (or content ""))
                  (f:close)
                  (ok (.. "wrote " (tostring (length (or content "")))
                          " bytes to " path))))))))

(fn run-ls [{: path : limit}]
  (let [target (or path ".")
        pipe (io.popen (.. "ls -1 " (shellquote target) " 2>&1") :r)]
    (if (not pipe) (err "io.popen failed")
        (let [out (or (pipe:read :*a) "")
              take (int-arg limit nil)]
          (pipe:close)
          (if (and take (> take 0))
              (let [lines []]
                (var taken 0)
                (each [line (string.gmatch out "[^\n]+")]
                  (when (< taken take)
                    (table.insert lines line)
                    (set taken (+ taken 1))))
                (ok (table.concat lines "\n")))
              (ok out))))))

;; --- edit -------------------------------------------------------

(fn find-all [s sub]
  "All 1-based start indices where literal `sub` occurs in `s`. Plain match,
   no pattern interpretation."
  (let [out []
        sub-len (length sub)]
    (var i 1)
    (var done? false)
    (while (not done?)
      (let [pos (string.find s sub i 1)]
        (if pos
            (do (table.insert out pos)
                (set i (+ pos sub-len)))
            (set done? true))))
    out))

(fn validate-edits [content edits]
  "Locate every edit's match. Each old_string must occur exactly once in
   the original content, and no two matches may overlap. Returns
   (matches nil) on success or (nil error-message) on failure."
  (let [matches []]
    (var error-msg nil)
    (each [i edit (ipairs edits)]
      (when (not error-msg)
        (let [old-str edit.old_string]
          (if (or (not old-str) (= old-str ""))
              (set error-msg (.. "edit " (tostring i) ": missing old_string"))
              (let [hits (find-all content old-str)]
                (if (= (length hits) 0)
                    (set error-msg (.. "edit " (tostring i)
                                       ": old_string not found"))
                    (> (length hits) 1)
                    (set error-msg (.. "edit " (tostring i)
                                       ": old_string is not unique ("
                                       (tostring (length hits))
                                       " matches)"))
                    (table.insert matches
                      {:start (. hits 1)
                       :end (+ (. hits 1) (length old-str) -1)
                       :new (or edit.new_string "")
                       :index i})))))))
    (when (not error-msg)
      (table.sort matches (fn [a b] (< a.start b.start)))
      (each [k cur (ipairs matches)]
        (when (and (not error-msg) (> k 1))
          (let [prev (. matches (- k 1))]
            (when (>= prev.end cur.start)
              (set error-msg (.. "edits " (tostring prev.index)
                                 " and " (tostring cur.index)
                                 " overlap")))))))
    (if error-msg (values nil error-msg) (values matches nil))))

(fn apply-edits [content matches]
  "Splice each match's replacement in from end to start so earlier index
   positions stay valid for later splices."
  (var result content)
  (for [k (length matches) 1 -1]
    (let [m (. matches k)]
      (set result
           (.. (string.sub result 1 (- m.start 1))
               m.new
               (string.sub result (+ m.end 1))))))
  result)

(fn run-edit [{: path : edits}]
  (if (or (not path) (= path ""))
      (err "missing 'path'")
      (or (not edits) (= (length edits) 0))
      (err "missing 'edits'")
      (let [(f open-err) (io.open path :r)]
        (if (not f) (err open-err)
            (let [content (f:read :*a)
                  _ (f:close)
                  (matches verr) (validate-edits content edits)]
              (if verr
                  (err verr)
                  (let [result (apply-edits content matches)
                        (wf werr) (io.open path :w)]
                    (if (not wf)
                        (err werr)
                        (do (wf:write result)
                            (wf:close)
                            (ok (.. "applied " (tostring (length edits))
                                    " edit(s) to " path)))))))))))

;; --- grep / find ------------------------------------------------

(fn run-grep [{: pattern : path : glob : ignore_case : literal : context : limit}]
  (if (or (not pattern) (= pattern ""))
      (err "missing 'pattern'")
      (let [target (or path ".")
            cap (int-arg limit 200)
            opts ["-rn"]]
        (when literal (table.insert opts "-F"))
        (when ignore_case (table.insert opts "-i"))
        (let [context-int (int-arg context nil)]
          (when (and context-int (> context-int 0))
            (table.insert opts (.. "-C " (tostring context-int)))))
        (when (and glob (not= glob ""))
          (table.insert opts (.. "--include=" (shellquote glob))))
        (let [cmd (.. "grep " (table.concat opts " ")
                      " -- " (shellquote pattern) " " (shellquote target)
                      " 2>&1 | head -n " (tostring cap))
              pipe (io.popen cmd :r)]
          (if (not pipe) (err "io.popen failed")
              (let [out (or (pipe:read :*a) "")]
                (pipe:close)
                (ok out)))))))

(fn run-find [{: pattern : path : limit}]
  (if (or (not pattern) (= pattern ""))
      (err "missing 'pattern'")
      (let [target (or path ".")
            cap (int-arg limit 200)
            cmd (.. "find " (shellquote target)
                    " -name " (shellquote pattern)
                    " -print 2>&1 | head -n " (tostring cap))
            pipe (io.popen cmd :r)]
        (if (not pipe) (err "io.popen failed")
            (let [out (or (pipe:read :*a) "")]
              (pipe:close)
              (ok out))))))

;; ----------------------------------------------------------------
;; Default registry
;; ----------------------------------------------------------------

(local registry
  [{:name :bash
    :label "Bash"
    :description "Run a shell command and return combined stdout/stderr."
    :parameters {:type :object
                 :properties {:cmd {:type :string
                                    :description "Shell command to run"}
                              :timeout {:type :integer
                                        :description "Kill the command after N seconds (uses timeout(1))"}}
                 :required [:cmd]}
    :execute run-bash}
   {:name :read
    :label "Read"
    :description "Read a file. Optional 1-indexed offset and a line limit slice the output."
    :parameters {:type :object
                 :properties {:path {:type :string :description "File path"}
                              :offset {:type :integer
                                       :description "1-indexed start line"}
                              :limit {:type :integer
                                      :description "Maximum number of lines to return"}}
                 :required [:path]}
    :execute run-read}
   {:name :write
    :label "Write"
    :description "Write content to a file (overwrites). Creates the parent directory if missing."
    :parameters {:type :object
                 :properties {:path {:type :string :description "File path"}
                              :content {:type :string :description "Content to write"}}
                 :required [:path :content]}
    :execute run-write}
   {:name :ls
    :label "Ls"
    :description "List entries in a directory."
    :parameters {:type :object
                 :properties {:path {:type :string :description "Directory (defaults to .)"}
                              :limit {:type :integer
                                      :description "Maximum number of entries to return"}}}
    :execute run-ls}
   {:name :edit
    :label "Edit"
    :description "Make exact-text replacements in a single file. Each old_string must match uniquely in the original; multiple disjoint edits per call are allowed and applied to the original snapshot, not sequentially."
    :parameters {:type :object
                 :properties {:path {:type :string :description "File path"}
                              :edits {:type :array
                                      :description "Replacements to apply"
                                      :items {:type :object
                                              :properties {:old_string {:type :string
                                                                        :description "Exact text to match (unique in file)"}
                                                           :new_string {:type :string
                                                                        :description "Replacement text"}}
                                              :required [:old_string :new_string]}}}
                 :required [:path :edits]}
    :execute run-edit}
   {:name :grep
    :label "Grep"
    :description "Search files for a regex pattern. Recursive when path is a directory."
    :parameters {:type :object
                 :properties {:pattern {:type :string :description "Pattern to search for"}
                              :path {:type :string :description "File or directory (default: .)"}
                              :glob {:type :string
                                     :description "Filename glob filter, e.g. *.fnl"}
                              :ignore_case {:type :boolean
                                            :description "Case-insensitive match"}
                              :literal {:type :boolean
                                        :description "Treat pattern as literal text, not regex"}
                              :context {:type :integer
                                        :description "Lines of context before/after each match"}
                              :limit {:type :integer
                                      :description "Maximum output lines (default 200)"}}
                 :required [:pattern]}
    :execute run-grep}
   {:name :find
    :label "Find"
    :description "Locate files by name glob, recursively."
    :parameters {:type :object
                 :properties {:pattern {:type :string
                                        :description "Glob pattern, e.g. *.fnl"}
                              :path {:type :string
                                     :description "Directory (default: .)"}
                              :limit {:type :integer
                                      :description "Maximum results (default 200)"}}
                 :required [:pattern]}
    :execute run-find}])

;; ----------------------------------------------------------------
;; Helpers
;; ----------------------------------------------------------------

(fn find-tool [reg name]
  (var found nil)
  (each [_ t (ipairs reg)]
    (when (and (= found nil) (= (tostring t.name) (tostring name)))
      (set found t)))
  found)

(fn descriptors [reg]
  "Strip execute/label → canonical Tool[] (the shape providers wrap)."
  (let [out []]
    (each [_ t (ipairs reg)]
      (table.insert out
                    {:name t.name
                     :description t.description
                     :parameters t.parameters}))
    out))

(fn execute [reg name args]
  "Look up a tool by name and run it. `args` is a parsed table (the provider
   has already JSON-decoded the wire arguments). Returns a canonical
   AgentToolResult."
  (let [t (find-tool reg name)]
    (if (not t)
        (err (.. "unknown tool: " (tostring name)))
        (t.execute (or args {})))))

{: registry : descriptors : execute : find-tool}
