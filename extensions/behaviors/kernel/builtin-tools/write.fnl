(local util (require :fen.extensions.builtin_tools.util))

(local WRITE-CHUNK-SIZE 16384)

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
;; signature: (execute args ctx? yield-fn?) -> AgentToolResult
;; summary: Write tool executor that creates missing parent directories, yields during large content writes, and reports byte counts.
;; tags: builtin tools write execution

(fn maybe-yield [?yield-fn]
  (when ?yield-fn (?yield-fn)))

(fn write-content [f content ?yield-fn]
  (let [s (or content "")
        total (length s)]
    (if (= total 0)
        (f:write "")
        (do
          (var i 1)
          (while (<= i total)
            (let [j (math.min total (+ i WRITE-CHUNK-SIZE -1))]
              (f:write (string.sub s i j))
              (set i (+ j 1))
              (maybe-yield ?yield-fn)))))))

(fn run-write [{: path : content} _ctx ?yield-fn]
  (if (or (not path) (= path ""))
      (util.err "missing 'path'")
      (do
        (maybe-yield ?yield-fn)
        (let [parent (string.match path "^(.*)/[^/]+$")]
          (when parent
            (os.execute (.. "mkdir -p " (util.shellquote parent)))
            (maybe-yield ?yield-fn)))
        (let [(f open-err) (io.open path :w)]
          (if (not f) (util.err open-err)
              (let [(ok? err) (xpcall #(write-content f content ?yield-fn)
                                      debug.traceback)]
                (f:close)
                (if ok?
                    (do
                      (maybe-yield ?yield-fn)
                      (util.ok (.. "wrote " (tostring (length (or content "")))
                                   " bytes to " path)))
                    (error err))))))))

{:name :write
 :label "Write"
 :snippet "Create or overwrite a file"
 :description "Write content to a file (overwrites). Creates the parent directory if missing."
 :parameters {:type :object
              :properties {:path {:type :string :description "File path"}
                           :content {:type :string :description "Content to write"}}
              :required [:path :content]}
 :execute run-write}
