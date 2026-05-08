(local util (require :fen.extensions.builtin_tools.util))

;; @doc fen.extensions.builtin_tools.edit.name
;; kind: data
;; signature: keyword
;; summary: Registry name for the built-in exact-replacement edit tool descriptor.
;; tags: builtin tools edit descriptor

;; @doc fen.extensions.builtin_tools.edit.edit
;; kind: data
;; signature: AgentToolSpec
;; summary: Complete edit tool specification exported for registration with batch and single-file replacement modes.
;; tags: builtin tools edit descriptor

;; @doc fen.extensions.builtin_tools.edit.label
;; kind: data
;; signature: string
;; summary: Human-readable label shown in tool-running status and generated listings for exact text edits.
;; tags: builtin tools edit ui

;; @doc fen.extensions.builtin_tools.edit.snippet
;; kind: data
;; signature: string
;; summary: Short edit tool teaser describing precise replacements for compact generated docs.
;; tags: builtin tools edit docs

;; @doc fen.extensions.builtin_tools.edit.description
;; kind: data
;; signature: string
;; summary: Provider-facing edit tool description covering uniqueness, snapshot application, and all-or-nothing batch validation.
;; tags: builtin tools edit docs

;; @doc fen.extensions.builtin_tools.edit.parameters
;; kind: data
;; signature: JSONSchema
;; summary: JSON schema for single-file and batch edit payloads, including exact old and replacement strings.
;; tags: builtin tools edit schema

;; @doc fen.extensions.builtin_tools.edit.execute
;; kind: function
;; signature: (execute args ctx?) -> AgentToolResult
;; summary: Edit tool executor that validates mutually exclusive modes, applies exact replacements, and reports write summaries.
;; tags: builtin tools edit execution

(fn find-all [s sub]
  "All 1-based start indices where literal sub occurs in s."
  (let [out []
        sub-len (length sub)]
    (var i 1)
    (var done? false)
    (while (not done?)
      (let [pos (string.find s sub i 1)]
        (if pos
            (do (table.insert out pos)
                (set i (+ pos sub-len)))
            (set done? true))))
    out))

(fn has-crlf? [s]
  (not= nil (string.find s "\r\n" 1 true)))

(fn validate-edits [content edits]
  "Locate every edit's match. Each old_string must occur exactly once."
  (let [matches []
        crlf? (has-crlf? content)]
    (var error-msg nil)
    (each [i edit (ipairs edits)]
      (when (not error-msg)
        (let [old-str edit.old_string]
          (if (or (not old-str) (= old-str ""))
              (set error-msg (.. "edit " (tostring i) ": missing old_string"))
              (let [hits (find-all content old-str)]
                (if (= (length hits) 0)
                    (set error-msg
                         (.. "edit " (tostring i) ": old_string not found"
                             (if (and crlf? (not (has-crlf? old-str)))
                                 " (file has CRLF line endings; old_string uses LF — try \\r\\n)"
                                 "")))
                    (> (length hits) 1)
                    (set error-msg (.. "edit " (tostring i)
                                       ": old_string is not unique ("
                                       (tostring (length hits))
                                       " matches)"))
                    (table.insert matches
                      {:start (. hits 1)
                       :end (+ (. hits 1) (length old-str) -1)
                       :new (or edit.new_string "")
                       :index i})))))))
    (when (not error-msg)
      (table.sort matches (fn [a b] (< a.start b.start)))
      (each [k cur (ipairs matches)]
        (when (and (not error-msg) (> k 1))
          (let [prev (. matches (- k 1))]
            (when (>= prev.end cur.start)
              (set error-msg (.. "edits " (tostring prev.index)
                                 " and " (tostring cur.index)
                                 " overlap")))))))
    (if error-msg (values nil error-msg) (values matches nil))))

(fn apply-edits [content matches]
  "Splice each match's replacement in from end to start."
  (var result content)
  (for [k (length matches) 1 -1]
    (let [m (. matches k)]
      (set result
           (.. (string.sub result 1 (- m.start 1))
               m.new
               (string.sub result (+ m.end 1))))))
  result)

(fn validate-edit-file [path edits]
  (if (or (not path) (= path ""))
      (values nil "missing 'path'")
      (or (not edits) (= (length edits) 0))
      (values nil "missing 'edits'")
      (let [(f open-err) (io.open path :r)]
        (if (not f) (values nil open-err)
            (let [content (f:read :*a)
                  _ (f:close)
                  (matches verr) (validate-edits content edits)]
              (if verr
                  (values nil verr)
                  (values {:path path
                           :edits edits
                           :content content
                           :matches matches}
                          nil)))))))

(fn write-edit-file [validated]
  (let [result (apply-edits validated.content validated.matches)
        (wf werr) (io.open validated.path :w)]
    (if (not wf)
        (values nil werr)
        (do (wf:write result)
            (wf:close)
            (values true nil)))))

(fn run-edit-one [{: path : edits}]
  (let [(validated verr) (validate-edit-file path edits)]
    (if verr
        (util.err verr)
        (let [(_ werr) (write-edit-file validated)]
          (if werr
              (util.err werr)
              (util.ok (.. "applied " (tostring (length edits))
                           " edit(s) to " path)))))))

(fn run-edit-batch [files]
  (if (or (not files) (= (length files) 0))
      (util.err "missing 'files'")
      (let [validated []
            seen {}]
        (var error-msg nil)
        (each [i f (ipairs files)]
          (when (not error-msg)
            (let [path (?. f :path)]
              (if (and path (. seen path))
                  (set error-msg (.. path ": duplicate path in files batch; combine edits for the same file in one entry"))
                  (do
                    (when path (tset seen path true))
                    (let [(v verr) (validate-edit-file path (?. f :edits))]
                      (if verr
                          (set error-msg (.. (or path (.. "file " (tostring i))) ": " verr))
                          (table.insert validated v))))))))
        (if error-msg
            (util.err error-msg)
            (let [summaries []]
              (var write-err nil)
              (each [_ v (ipairs validated)]
                (when (not write-err)
                  (let [(_ werr) (write-edit-file v)]
                    (if werr
                        (set write-err (.. v.path ": " werr))
                        (table.insert summaries
                                      (.. "applied " (tostring (length v.edits))
                                          " edit(s) to " v.path))))))
              (if write-err
                  (util.err write-err)
                  (util.ok (table.concat summaries "\n"))))))))

(fn run-edit [args]
  (let [has-single? (or (and args.path (not= args.path ""))
                         (not= args.edits nil))
        has-files? (not= args.files nil)]
    (if (and has-single? has-files?)
        (util.err "provide either 'path'/'edits' or 'files', not both")
        has-files?
        (run-edit-batch args.files)
        (run-edit-one args))))

{:name :edit
 :label "Edit"
 :snippet "Make exact-text replacements in one or more files"
 :description "Make exact-text replacements. Single-file shape: {path, edits}. Batch shape: {files:[{path, edits}, ...]}. Each old_string must match uniquely in the original; multiple disjoint edits per file are applied to the original snapshot, not sequentially. Batch validation is all-or-nothing: if any file fails validation, no file is mutated. After validation succeeds, files are written sequentially; a rare write failure can leave earlier files already written."
 :parameters {:type :object
              :properties {:path {:type :string
                                  :description "File path for single-file edits; mutually exclusive with files"}
                           :edits {:type :array
                                   :description "Replacements to apply to path"
                                   :items {:type :object
                                           :properties {:old_string {:type :string
                                                                     :description "Exact text to match (unique in file)"}
                                                        :new_string {:type :string
                                                                     :description "Replacement text"}}
                                           :required [:old_string :new_string]}}
                           :files {:type :array
                                   :description "Batch edits across files in one call; mutually exclusive with path/edits"
                                   :items {:type :object
                                           :properties {:path {:type :string
                                                               :description "File path"}
                                                        :edits {:type :array
                                                                :description "Replacements to apply"
                                                                :items {:type :object
                                                                        :properties {:old_string {:type :string
                                                                                                  :description "Exact text to match (unique in file)"}
                                                                                     :new_string {:type :string
                                                                                                  :description "Replacement text"}}
                                                                        :required [:old_string :new_string]}}}
                                           :required [:path :edits]}}}}
 :execute run-edit}
