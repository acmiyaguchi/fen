(local util (require :core.tools.util))
(local truncate (require :core.tools.truncate))

(fn run-read-one [{: path : offset : limit}]
  (if (or (not path) (= path ""))
      (util.err "missing 'path'")
      (let [(f open-err) (io.open path :r)]
        (if (not f) (util.err open-err)
            (if (and (not offset) (not limit))
                (let [content (f:read :*a)
                      _ (f:close)
                      (capped _) (truncate.truncate-head content nil)]
                  (util.ok capped))
                (let [start (util.int-arg offset 1)
                      take (or (util.int-arg limit nil) math.huge)
                      lines []]
                  (var n 0)
                  (each [line (f:lines)]
                    (set n (+ n 1))
                    (when (and (>= n start) (< (length lines) take))
                      (table.insert lines line)))
                  (f:close)
                  (util.ok (table.concat lines "\n"))))))))

(fn normalize-read-spec [spec]
  (if (= (type spec) :string)
      {:path spec}
      spec))

(fn run-read-batch [paths]
  (if (or (not paths) (= (length paths) 0))
      (util.err "missing 'paths'")
      (let [parts []]
        (each [_ raw (ipairs paths)]
          (let [spec (normalize-read-spec raw)
                path (?. spec :path)
                header (.. "==> " (or path "<missing path>") " <==")
                r (run-read-one (or spec {}))]
            (table.insert parts (.. header "\n" (util.result-text r)))))
        (util.ok (table.concat parts "\n\n")))))

(fn run-read [args]
  (let [has-path? (and args.path (not= args.path ""))
        has-paths? (not= args.paths nil)]
    (if (and has-path? has-paths?)
        (util.err "provide either 'path' or 'paths', not both")
        has-paths?
        (run-read-batch args.paths)
        (run-read-one args))))

{:name :read
 :label "Read"
 :snippet "Read a file's contents"
 :description "Read one or more files. Single-file shape: {path, optional offset/limit}. Batch shape: {paths:[path-or-{path,offset,limit}, ...]}. Default full slurp is head-truncated per file to ~50KB / 2000 lines; when truncated, the tag includes a `full output: <path>` you can pass back to this tool with offset/limit to page explicitly through the original. In batched reads, missing/unreadable files are reported inline under that path's header; the overall call still succeeds."
 :parameters {:type :object
              :properties {:path {:type :string
                                  :description "File path for single-file reads; mutually exclusive with paths"}
                           :paths {:type :array
                                   :description "Batch multiple reads in one call. Items may be path strings or {path, offset, limit} objects; mutually exclusive with path."
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
