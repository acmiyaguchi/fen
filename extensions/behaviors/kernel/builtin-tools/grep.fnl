(local util (require :fen.extensions.builtin_tools.util))
(local truncate (require :fen.extensions.builtin_tools.truncate))
(local process (require :fen.util.process))

;; @doc fen.extensions.builtin_tools.grep.name
;; kind: data
;; signature: keyword
;; summary: Registry name for the built-in recursive grep tool descriptor.
;; tags: builtin tools grep descriptor

;; @doc fen.extensions.builtin_tools.grep.grep
;; kind: data
;; signature: AgentToolSpec
;; summary: Complete grep tool specification exported for content search through the built-in registry.
;; tags: builtin tools grep descriptor

;; @doc fen.extensions.builtin_tools.grep.label
;; kind: data
;; signature: string
;; summary: Human-readable label shown in tool-running status and generated listings for text searches.
;; tags: builtin tools grep ui

;; @doc fen.extensions.builtin_tools.grep.snippet
;; kind: data
;; signature: string
;; summary: Short grep tool teaser used by generated docs before the full search option contract.
;; tags: builtin tools grep docs

;; @doc fen.extensions.builtin_tools.grep.description
;; kind: data
;; signature: string
;; summary: Provider-facing grep tool description covering recursive regex search behavior.
;; tags: builtin tools grep docs

;; @doc fen.extensions.builtin_tools.grep.parameters
;; kind: data
;; signature: JSONSchema
;; summary: JSON schema for grep arguments, including pattern, path, glob, literal, case, context, and limit controls.
;; tags: builtin tools grep schema

;; @doc fen.extensions.builtin_tools.grep.execute
;; kind: function
;; signature: (execute args ctx? yield-fn?) -> AgentToolResult
;; summary: Grep tool executor that builds a POSIX grep pipeline, enforces an output limit, and cooperatively drains matches when a yield-fn is provided.
;; tags: builtin tools grep execution

(fn read-pipe [pipe ?yield-fn]
  (process.read-pipe-close pipe ?yield-fn))

(fn run-grep [{: pattern : path : glob : ignore_case : literal : context : limit} _ctx ?yield-fn]
  (if (or (not pattern) (= pattern ""))
      (util.err "missing 'pattern'")
      (let [target (or path ".")
            cap (util.int-arg limit 200)
            opts ["-rn"]]
        (when literal (table.insert opts "-F"))
        (when ignore_case (table.insert opts "-i"))
        (let [context-int (util.int-arg context nil)]
          (when (and context-int (> context-int 0))
            (table.insert opts (.. "-C " (tostring context-int)))))
        (when (and glob (not= glob ""))
          (table.insert opts (.. "--include=" (util.shellquote glob))))
        (let [cmd (.. "grep " (table.concat opts " ")
                      " -- " (util.shellquote pattern) " " (util.shellquote target)
                      " 2>&1 | head -n " (tostring cap))
              pipe (io.popen cmd :r)]
          (if (not pipe) (util.err "io.popen failed")
              (let [out (read-pipe pipe ?yield-fn)
                    (capped _) (truncate.truncate-head out nil ?yield-fn)]
                (util.ok capped)))))))

{:name :grep
 :label "Grep"
 :snippet "Search file contents with regex"
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
