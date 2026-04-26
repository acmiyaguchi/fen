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

(local types (require :core.types))

(fn agent-result [content is-error? details]
  (let [r {:content content :is-error? (or is-error? false)}]
    (when (not= details nil) (set r.details details))
    r))

(fn ok [text]
  (agent-result [(types.text-block (or text ""))] false nil))

(fn err [message]
  (agent-result [(types.text-block (.. "error: " message))] true nil))

;; ----------------------------------------------------------------
;; Built-in tool implementations
;; ----------------------------------------------------------------

(fn run-bash [{: cmd}]
  (if (or (not cmd) (= cmd ""))
      (err "missing 'cmd'")
      (let [pipe (io.popen (.. cmd " 2>&1") :r)]
        (if (not pipe) (err "io.popen failed")
            (let [out (pipe:read :*a)
                  (_ _ code) (pipe:close)]
              (ok (.. (or out "") "\n[exit " (tostring (or code 0)) "]")))))))

(fn run-read [{: path}]
  (if (or (not path) (= path ""))
      (err "missing 'path'")
      (let [(f open-err) (io.open path :r)]
        (if (not f) (err open-err)
            (let [content (f:read :*a)]
              (f:close)
              (ok content))))))

(fn run-write [{: path : content}]
  (if (or (not path) (= path ""))
      (err "missing 'path'")
      (let [(f open-err) (io.open path :w)]
        (if (not f) (err open-err)
            (do (f:write (or content ""))
                (f:close)
                (ok (.. "wrote " (tostring (length (or content ""))) " bytes to " path)))))))

(fn shellquote [s]
  (.. "'" (string.gsub s "'" "'\\''") "'"))

(fn run-ls [{: path}]
  (let [target (or path ".")
        pipe (io.popen (.. "ls -1 " (shellquote target) " 2>&1") :r)]
    (if (not pipe) (err "io.popen failed")
        (let [out (pipe:read :*a)]
          (pipe:close)
          (ok (or out ""))))))

;; ----------------------------------------------------------------
;; Default registry
;; ----------------------------------------------------------------

(local registry
  [{:name :bash
    :label "Bash"
    :description "Run a shell command and return combined stdout/stderr."
    :parameters {:type :object
                 :properties {:cmd {:type :string
                                    :description "Shell command to run"}}
                 :required [:cmd]}
    :execute run-bash}
   {:name :read
    :label "Read"
    :description "Read the entire contents of a file."
    :parameters {:type :object
                 :properties {:path {:type :string :description "File path"}}
                 :required [:path]}
    :execute run-read}
   {:name :write
    :label "Write"
    :description "Write content to a file (overwrites)."
    :parameters {:type :object
                 :properties {:path {:type :string :description "File path"}
                              :content {:type :string :description "Content to write"}}
                 :required [:path :content]}
    :execute run-write}
   {:name :ls
    :label "Ls"
    :description "List entries in a directory."
    :parameters {:type :object
                 :properties {:path {:type :string :description "Directory (defaults to .)"}}}
    :execute run-ls}])

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
