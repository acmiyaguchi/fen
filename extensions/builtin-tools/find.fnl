(local util (require :fen.extensions.builtin_tools.util))
(local truncate (require :fen.extensions.builtin_tools.truncate))

;; @doc fen.extensions.builtin_tools.find.name
;; kind: data
;; signature: keyword
;; summary: Registry name for the built-in recursive file find tool descriptor.
;; tags: builtin tools find descriptor

;; @doc fen.extensions.builtin_tools.find.find
;; kind: data
;; signature: AgentToolSpec
;; summary: Complete find tool specification exported for name-glob file discovery through the built-in registry.
;; tags: builtin tools find descriptor

;; @doc fen.extensions.builtin_tools.find.label
;; kind: data
;; signature: string
;; summary: Human-readable label shown in tool-running status and generated listings for file discovery.
;; tags: builtin tools find ui

;; @doc fen.extensions.builtin_tools.find.snippet
;; kind: data
;; signature: string
;; summary: Short find tool teaser used by generated docs and compact tool summaries.
;; tags: builtin tools find docs

;; @doc fen.extensions.builtin_tools.find.description
;; kind: data
;; signature: string
;; summary: Provider-facing find tool description for recursive filename-glob searches.
;; tags: builtin tools find docs

;; @doc fen.extensions.builtin_tools.find.parameters
;; kind: data
;; signature: JSONSchema
;; summary: JSON schema for find arguments, including required name glob, optional root path, and result limit.
;; tags: builtin tools find schema

;; @doc fen.extensions.builtin_tools.find.execute
;; kind: function
;; signature: (execute args ctx?) -> AgentToolResult
;; summary: Find tool executor that shells out to POSIX find, limits result lines, and caps long output.
;; tags: builtin tools find execution

(fn run-find [{: pattern : path : limit}]
  (if (or (not pattern) (= pattern ""))
      (util.err "missing 'pattern'")
      (let [target (or path ".")
            cap (util.int-arg limit 200)
            cmd (.. "find " (util.shellquote target)
                    " -name " (util.shellquote pattern)
                    " -print 2>&1 | head -n " (tostring cap))
            pipe (io.popen cmd :r)]
        (if (not pipe) (util.err "io.popen failed")
            (let [out (or (pipe:read :*a) "")
                  (capped _) (truncate.truncate-head out nil)]
              (pipe:close)
              (util.ok capped))))))

{:name :find
 :label "Find"
 :snippet "Find files by name pattern"
 :description "Locate files by name glob, recursively."
 :parameters {:type :object
              :properties {:pattern {:type :string
                                     :description "Glob pattern, e.g. *.fnl"}
                           :path {:type :string
                                  :description "Directory (default: .)"}
                           :limit {:type :integer
                                   :description "Maximum results (default 200)"}}
              :required [:pattern]}
 :execute run-find}
