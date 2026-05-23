(local util (require :fen.extensions.builtin_tools.util))
(local truncate (require :fen.extensions.builtin_tools.truncate))

(local READ-CHUNK-SIZE 16384)
(local LINES-BEFORE-YIELD 512)

;; @doc fen.extensions.builtin_tools.read.name
;; kind: data
;; signature: keyword
;; summary: Registry name for the built-in file read tool descriptor.
;; tags: builtin tools read descriptor

;; @doc fen.extensions.builtin_tools.read.read
;; kind: data
;; signature: AgentToolSpec
;; summary: Complete read tool specification exported for single-file and batched file inspection.
;; tags: builtin tools read descriptor

;; @doc fen.extensions.builtin_tools.read.label
;; kind: data
;; signature: string
;; summary: Human-readable label shown in tool-running status and generated listings for file reads.
;; tags: builtin tools read ui

;; @doc fen.extensions.builtin_tools.read.snippet
;; kind: data
;; signature: string
;; summary: Short read tool teaser used by generated docs before the full paging and truncation contract.
;; tags: builtin tools read docs

;; @doc fen.extensions.builtin_tools.read.description
;; kind: data
;; signature: string
;; summary: Provider-facing read tool description covering full slurps, offset/limit paging, batched reads, and truncation tags.
;; tags: builtin tools read docs

;; @doc fen.extensions.builtin_tools.read.parameters
;; kind: data
;; signature: JSONSchema
;; summary: JSON schema for read arguments, including path, batched paths, and optional line window controls.
;; tags: builtin tools read schema

;; @doc fen.extensions.builtin_tools.read.execute
;; kind: function
;; signature: (execute args ctx? yield-fn?) -> AgentToolResult
;; summary: Read tool executor that dispatches single or batch reads, yielding during large file and batch work when cooperative.
;; tags: builtin tools read execution

(fn maybe-yield [?yield-fn]
  (when ?yield-fn (?yield-fn)))

(fn read-all-coop [f ?yield-fn]
  (let [chunks []]
    (var done? false)
    (while (not done?)
      (let [chunk (f:read READ-CHUNK-SIZE)]
        (if chunk
            (do (table.insert chunks chunk)
                (maybe-yield ?yield-fn))
            (set done? true))))
    (table.concat chunks)))

(fn read-lines-slice [f start take ?yield-fn]
  (let [lines []]
    (var n 0)
    (var scanned 0)
    (each [line (f:lines)]
      (set n (+ n 1))
      (set scanned (+ scanned 1))
      (when (and (>= n start) (< (length lines) take))
        (table.insert lines line))
      (when (and ?yield-fn (>= scanned LINES-BEFORE-YIELD))
        (set scanned 0)
        (?yield-fn)))
    (table.concat lines "\n")))

(fn run-read-one [{: path : offset : limit} ?yield-fn]
  (if (or (not path) (= path ""))
      (util.err "missing 'path'")
      (let [(f open-err) (io.open path :r)]
        (if (not f) (util.err open-err)
            (if (and (not offset) (not limit))
                (let [content (read-all-coop f ?yield-fn)
                      _ (f:close)
                      (capped _) (truncate.truncate-head content nil)]
                  (util.ok capped))
                (let [start (util.int-arg offset 1)
                      take (or (util.int-arg limit nil) math.huge)
                      out (read-lines-slice f start take ?yield-fn)]
                  (f:close)
                  (util.ok out)))))))

(fn normalize-read-spec [spec]
  (if (= (type spec) :string)
      {:path spec}
      spec))

(fn run-read-batch [paths ?yield-fn]
  (if (or (not paths) (= (length paths) 0))
      (util.err "missing 'paths'")
      (let [parts []]
        (each [_ raw (ipairs paths)]
          (let [spec (normalize-read-spec raw)
                path (?. spec :path)
                header (.. "==> " (or path "<missing path>") " <==")
                r (run-read-one (or spec {}) ?yield-fn)]
            (table.insert parts (.. header "\n" (util.result-text r)))
            (maybe-yield ?yield-fn)))
        (util.ok (table.concat parts "\n\n")))))

(fn run-read [args _ctx ?yield-fn]
  (let [has-path? (and args.path (not= args.path ""))
        has-paths? (not= args.paths nil)]
    (if (and has-path? has-paths?)
        (util.err "provide either 'path' or 'paths', not both")
        has-paths?
        (run-read-batch args.paths ?yield-fn)
        (run-read-one args ?yield-fn))))

{:name :read
 :label "Read"
 :snippet "Read a file's contents"
 :description "Read one or more files. Prefer the batch shape `{paths:[...]}` whenever multiple independent files are needed; do not emit separate read calls for files you already know you need. Single-file shape: {path, optional offset/limit}. Batch shape: {paths:[path-or-{path,offset,limit}, ...]}, e.g. {paths:[\"src/a.fnl\", {path:\"src/b.fnl\", offset:10, limit:40}]}. Default full slurp is head-truncated per file to ~50KB / 2000 lines; when truncated, the tag includes a `full output: <path>` you can pass back to this tool with offset/limit to page explicitly through the original. In batched reads, missing/unreadable files are reported inline under that path's header; the overall call still succeeds."
 :parameters {:type :object
              :properties {:path {:type :string
                                  :description "File path for single-file reads; mutually exclusive with paths"}
                           :paths {:type :array
                                   :description "Preferred for multiple independent reads. Batch several files in one call. Items may be path strings or {path, offset, limit} objects; mutually exclusive with path."
                                   :items {:anyOf [{:type :string}
                                                   {:type :object
                                                    :properties {:path {:type :string}
                                                                 :offset {:type :integer}
                                                                 :limit {:type :integer}}
                                                    :required [:path]}]}}
                           :offset {:type :integer
                                    :description "1-indexed start line for single-file reads"}
                           :limit {:type :integer
                                   :description "Maximum number of lines to return"}}}
 :execute run-read}
