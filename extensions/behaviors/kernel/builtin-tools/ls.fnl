(local util (require :fen.extensions.builtin_tools.util))
(local truncate (require :fen.extensions.builtin_tools.truncate))
(local process (require :fen.util.process))

(local DEFAULT-LIMIT truncate.DEFAULT-MAX-LINES)

;; @doc fen.extensions.builtin_tools.ls.name
;; kind: data
;; signature: keyword
;; summary: Registry name for the built-in directory listing tool descriptor.
;; tags: builtin tools ls descriptor

;; @doc fen.extensions.builtin_tools.ls.ls
;; kind: data
;; signature: AgentToolSpec
;; summary: Complete ls tool specification exported for listing directory entries through the built-in registry.
;; tags: builtin tools ls descriptor

;; @doc fen.extensions.builtin_tools.ls.label
;; kind: data
;; signature: string
;; summary: Human-readable label shown in tool-running status and generated listings for directory scans.
;; tags: builtin tools ls ui

;; @doc fen.extensions.builtin_tools.ls.snippet
;; kind: data
;; signature: string
;; summary: Short ls tool teaser used by generated docs and compact tool summaries.
;; tags: builtin tools ls docs

;; @doc fen.extensions.builtin_tools.ls.description
;; kind: data
;; signature: string
;; summary: Provider-facing ls tool description for shallow directory entry listings.
;; tags: builtin tools ls docs

;; @doc fen.extensions.builtin_tools.ls.parameters
;; kind: data
;; signature: JSONSchema
;; summary: JSON schema for ls arguments, including optional target directory and output line limit.
;; tags: builtin tools ls schema

;; @doc fen.extensions.builtin_tools.ls.execute
;; kind: function
;; signature: (execute args ctx? yield-fn?) -> AgentToolResult
;; summary: Ls tool executor that shells out to POSIX ls, cooperatively drains output when a yield-fn is provided, applies optional limits, and caps long output.
;; tags: builtin tools ls execution

(fn read-pipe [pipe ?yield-fn]
  (process.read-pipe-close pipe ?yield-fn))

(fn run-ls [{: path : limit} _ctx ?yield-fn]
  (let [target (or path ".")
        take (math.max 1 (util.int-arg limit DEFAULT-LIMIT))
        explicit-limit? (not= (util.int-arg limit nil) nil)
        probe (+ take 1)
        pipe (io.popen (.. "ls -1 " (util.shellquote target)
                         " 2>&1 | head -n " (tostring probe)) :r)]
    (if (not pipe) (util.err "io.popen failed")
        (let [out (read-pipe pipe ?yield-fn)
              lines []]
          (var n 0)
          (each [line (string.gmatch out "[^\n]+")]
            (set n (+ n 1))
            (when (<= n take)
              (table.insert lines line)))
          (when (and (> n take) (not explicit-limit?))
            (table.insert lines (.. "[truncated: output capped at "
                                    (tostring take) " lines]")))
          (util.ok (table.concat lines "\n"))))))

{:name :ls
 :label "Ls"
 :snippet "List directory contents"
 :description "List entries in a directory."
 :parameters {:type :object
              :properties {:path {:type :string :description "Directory (defaults to .)"}
                           :limit {:type :integer
                                   :description "Maximum number of entries to return"}}}
 :execute run-ls}
