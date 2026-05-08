(local util (require :fen.extensions.builtin_tools.util))

;; @doc fen.extensions.builtin_tools.write.name
;; kind: data
;; signature: keyword
;; summary: Registry name for the built-in file write tool descriptor.
;; tags: builtin tools write descriptor

;; @doc fen.extensions.builtin_tools.write.write
;; kind: data
;; signature: AgentToolSpec
;; summary: Complete write tool specification exported for creating or overwriting files.
;; tags: builtin tools write descriptor

;; @doc fen.extensions.builtin_tools.write.label
;; kind: data
;; signature: string
;; summary: Human-readable label shown in tool-running status and generated listings for file writes.
;; tags: builtin tools write ui

;; @doc fen.extensions.builtin_tools.write.snippet
;; kind: data
;; signature: string
;; summary: Short write tool teaser used by generated docs and compact tool summaries.
;; tags: builtin tools write docs

;; @doc fen.extensions.builtin_tools.write.description
;; kind: data
;; signature: string
;; summary: Provider-facing write tool description documenting overwrite semantics and parent-directory creation.
;; tags: builtin tools write docs

;; @doc fen.extensions.builtin_tools.write.parameters
;; kind: data
;; signature: JSONSchema
;; summary: JSON schema for write arguments containing the destination path and complete file content.
;; tags: builtin tools write schema

;; @doc fen.extensions.builtin_tools.write.execute
;; kind: function
;; signature: (execute args ctx?) -> AgentToolResult
;; summary: Write tool executor that creates missing parent directories, writes content, and reports byte counts.
;; tags: builtin tools write execution

(fn run-write [{: path : content}]
  (if (or (not path) (= path ""))
      (util.err "missing 'path'")
      (do
        (let [parent (string.match path "^(.*)/[^/]+$")]
          (when parent
            (os.execute (.. "mkdir -p " (util.shellquote parent)))))
        (let [(f open-err) (io.open path :w)]
          (if (not f) (util.err open-err)
              (do (f:write (or content ""))
                  (f:close)
                  (util.ok (.. "wrote " (tostring (length (or content "")))
                               " bytes to " path))))))))

{:name :write
 :label "Write"
 :snippet "Create or overwrite a file"
 :description "Write content to a file (overwrites). Creates the parent directory if missing."
 :parameters {:type :object
              :properties {:path {:type :string :description "File path"}
                           :content {:type :string :description "Content to write"}}
              :required [:path :content]}
 :execute run-write}
