(local util (require :fen.extensions.builtin_tools.util))
(local truncate (require :fen.extensions.builtin_tools.truncate))

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
;; signature: (execute args ctx?) -> AgentToolResult
;; summary: Ls tool executor that shells out to POSIX ls, applies optional limits, and caps long output.
;; tags: builtin tools ls execution

(fn run-ls [{: path : limit}]
  (let [target (or path ".")
        pipe (io.popen (.. "ls -1 " (util.shellquote target) " 2>&1") :r)]
    (if (not pipe) (util.err "io.popen failed")
        (let [out (or (pipe:read :*a) "")
              take (util.int-arg limit nil)]
          (pipe:close)
          (if (and take (> take 0))
              (let [lines []]
                (var taken 0)
                (each [line (string.gmatch out "[^\n]+")]
                  (when (< taken take)
                    (table.insert lines line)
                    (set taken (+ taken 1))))
                (util.ok (table.concat lines "\n")))
              (let [(capped _) (truncate.truncate-head out nil)]
                (util.ok capped)))))))

{:name :ls
 :label "Ls"
 :snippet "List directory contents"
 :description "List entries in a directory."
 :parameters {:type :object
              :properties {:path {:type :string :description "Directory (defaults to .)"}
                           :limit {:type :integer
                                   :description "Maximum number of entries to return"}}}
 :execute run-ls}
