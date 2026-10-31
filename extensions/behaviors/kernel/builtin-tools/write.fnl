(local util (require :fen.extensions.builtin_tools.util))
(local file-mutex (require :fen.util.file_mutex))
(local commit (require :fen.extensions.builtin_tools.commit))

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
;; summary: Write tool executor that creates missing parent directories, stages content to a temp file (yielding between chunks), renames it over the target under the cross-process path lock, and reports byte counts or the write error.
;; tags: builtin tools write execution

(fn maybe-yield [?yield-fn]
  (when ?yield-fn (?yield-fn)))

(fn run-write-locked [path content ?yield-fn]
  ;; Stage to a temp beside the target (yields), then rename it over the
  ;; target and return with no yield in between (#654, #655, #656).
  (let [real (file-mutex.canonical-path path)
        (ok? target-err) (commit.check-target real)]
    (if (not ok?) (util.err target-err)
        (let [(tmp stage-err) (commit.stage! real content ?yield-fn)]
          (if (not tmp) (util.err stage-err)
              (let [(committed? commit-err) (commit.commit! tmp real)]
                (if committed?
                    (util.ok (.. "wrote " (tostring (length (or content "")))
                                 " bytes to " path))
                    (util.err commit-err))))))))

(fn run-write [{: path : content} _ctx ?yield-fn]
  (if (or (not path) (= path ""))
      (util.err "missing 'path'")
      (do
        (maybe-yield ?yield-fn)
        (let [parent (string.match path "^(.*)/[^/]+$")]
          (when (and parent (not= parent ""))
            (os.execute (.. "mkdir -p " (util.shellquote parent)))
            (maybe-yield ?yield-fn)))
        (file-mutex.with-files [path] ?yield-fn
          #(run-write-locked path content ?yield-fn)))))

{:name :write
 :label "Write"
 :snippet "Create or overwrite a file"
 :description "Write content to a file (overwrites). Creates the parent directory if missing. The file is replaced atomically: readers see the old or the new content, and a failed or cancelled write leaves the file unchanged."
 :parameters {:type :object
              :properties {:path {:type :string :description "File path"}
                           :content {:type :string
                                     :description "Content to write"}}
              :required [:path :content]}
 :execute run-write}
