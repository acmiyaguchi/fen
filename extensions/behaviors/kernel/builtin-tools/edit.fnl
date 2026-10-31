(local util (require :fen.extensions.builtin_tools.util))
(local file-mutex (require :fen.util.file_mutex))
(local commit (require :fen.extensions.builtin_tools.commit))
(local text (require :fen.util.text))

(local LINES-BEFORE-YIELD 512)
(local MAX-MATCH-SITES 10)
(local MAX-CONTEXT-BYTES 120)

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
;; signature: (execute args ctx? yield-fn?) -> AgentToolResult
;; summary: Edit tool executor that validates mutually exclusive modes, yields between large validation/write phases, applies exact replacements, and reports write summaries.
;; tags: builtin tools edit execution

(fn maybe-yield [?yield-fn]
  (when ?yield-fn (?yield-fn)))

(fn find-all [s sub ?yield-fn]
  "All 1-based start indices where literal sub occurs in s, overlapping
   occurrences included (#658): \"}\\n}\" occurs twice in \"}\\n}\\n}\"."
  (let [out []]
    (var i 1)
    (var done? false)
    (while (not done?)
      (let [pos (string.find s sub i 1)]
        (if pos
            (do
              (table.insert out pos)
              (set i (+ pos 1))
              (when (and ?yield-fn (= (% (length out) LINES-BEFORE-YIELD) 0))
                (?yield-fn)))
            (set done? true))))
    out))

(fn has-crlf? [s]
  (not= nil (string.find s "\r\n" 1 true)))

(fn line-context [content line-start]
  (let [line-end (- (or (string.find content "\n" line-start true)
                        (+ (length content) 1)) 1)
        line (string.gsub (string.sub content line-start line-end) "\r$" "")]
    (if (> (length line) MAX-CONTEXT-BYTES)
        (.. (text.utf8-prefix line MAX-CONTEXT-BYTES) "...")
        line)))

(fn match-sites-message [content hits ?yield-fn]
  "Describe the first match sites in one forward scan over content."
  (let [shown (math.min (length hits) MAX-MATCH-SITES)
        sites []]
    (var line 1)
    (var line-start 1)
    (var scanned 0)
    (for [i 1 shown]
      (let [pos (. hits i)]
        (var nl (string.find content "\n" line-start true))
        (while (and nl (< nl pos))
          (set line (+ line 1))
          (set line-start (+ nl 1))
          (set scanned (+ scanned 1))
          (when (= (% scanned LINES-BEFORE-YIELD) 0)
            (maybe-yield ?yield-fn))
          (set nl (string.find content "\n" line-start true)))
        (table.insert sites
                      (.. "line " (tostring line) ": "
                          (line-context content line-start)))))
    (.. "\nmatch sites:\n" (table.concat sites "\n")
        (if (> (length hits) shown)
            (.. "\nand " (tostring (- (length hits) shown)) " more")
            ""))))

(fn validate-edits [content edits ?yield-fn]
  "Locate every edit's match. Each old_string must occur exactly once."
  (let [matches []
        crlf? (has-crlf? content)]
    (var error-msg nil)
    (each [i edit (ipairs edits)]
      (when (not error-msg)
        (let [old-str edit.old_string]
          (if (or (not old-str) (= old-str ""))
              (set error-msg (.. "edit " (tostring i) ": missing old_string"))
              (let [hits (find-all content old-str ?yield-fn)]
                (maybe-yield ?yield-fn)
                (if (= (length hits) 0)
                    (set error-msg
                         (.. "edit " (tostring i) ": old_string not found"
                             (if (and crlf? (not (has-crlf? old-str)))
                                 " (file has CRLF line endings; old_string uses LF — try \\r\\n)"
                                 "")))
                    (> (length hits) 1)
                    (set error-msg
                         (.. "edit " (tostring i)
                             ": old_string is not unique ("
                             (tostring (length hits)) " matches)"
                             (match-sites-message content hits ?yield-fn)))
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
              (set error-msg
                   (.. "edits " (tostring prev.index) " and "
                       (tostring cur.index) " overlap")))))))
    (if error-msg (values nil error-msg) (values matches nil))))

(fn apply-edits [content matches]
  "Splice each match's replacement in from end to start."
  (var result content)
  (for [k (length matches) 1 -1]
    (let [m (. matches k)]
      (set result (.. (string.sub result 1 (- m.start 1)) m.new
                      (string.sub result (+ m.end 1))))))
  result)

(fn validate-edit-file [path edits ?yield-fn]
  (if (or (not path) (= path ""))
      (values nil "missing 'path'")
      (or (not edits) (= (length edits) 0))
      (values nil "missing 'edits'")
      (let [(f open-err) (io.open path :r)]
        (if (not f) (values nil open-err)
            (let [content (f:read :*a)
                  _ (f:close)]
              (maybe-yield ?yield-fn)
              (let [(matches verr) (validate-edits content edits ?yield-fn)]
                (if verr
                    (values nil verr)
                    (values {:path path
                             :edits edits
                             :content content
                             :matches matches} nil))))))))

(fn commit-staged! [staged]
  "Re-check every target against its snapshot, then rename every temp over
   its target. No yield from here to the caller's return, so a cancel cannot
   land between files or after the commit (#656). Returns summaries or nil,
   error; on error nothing was renamed unless a rename itself failed."
  (var changed nil)
  (each [_ st (ipairs staged)]
    (when (and (not changed) (commit.changed? st.real st.content))
      (set changed st)))
  (if changed
      (do
        (commit.discard! (icollect [_ st (ipairs staged)] st.tmp))
        (values nil
                (.. changed.path
                    ": file changed since it was read; re-read it and retry")))
      (let [applied []]
        (var rename-err nil)
        (each [i st (ipairs staged)]
          (if rename-err
              (commit.discard! [st.tmp])
              (let [(ok? err) (commit.commit! st.tmp st.real)]
                (if ok?
                    (table.insert applied st)
                    (set rename-err
                         (.. err (if (> i 1)
                                     (.. "; already applied: "
                                         (table.concat (icollect [_ a (ipairs applied)]
                                                         a.path)
                                                       ", "))
                                     "")))))))
        (if rename-err
            (values nil rename-err)
            (icollect [_ st (ipairs staged)]
              (.. "applied " (tostring (length st.edits)) " edit(s) to "
                  st.path))))))

(fn stage-all! [validated ?yield-fn]
  "Stage every validated file's result to a temp beside it (yields allowed:
   targets are untouched). A failure or a raise removes every temp."
  (let [staged []
        (ok? err) (pcall (fn []
                           (var stage-err nil)
                           (each [_ v (ipairs validated)]
                             (when (not stage-err)
                               (let [real (file-mutex.canonical-path v.path)
                                     (target-ok? target-err) (commit.check-target real)
                                     (tmp terr) (if target-ok?
                                                    (commit.stage! real
                                                                   (apply-edits v.content
                                                                                v.matches)
                                                                   ?yield-fn)
                                                    (values nil target-err))]
                                 (if tmp
                                     (table.insert staged
                                                   {:path v.path
                                                    : real
                                                    : tmp
                                                    :content v.content
                                                    :edits v.edits})
                                     (set stage-err terr)))))
                           stage-err))]
    (if (not ok?)
        (do
          (commit.discard! (icollect [_ st (ipairs staged)] st.tmp))
          (error err 0))
        err
        (do
          (commit.discard! (icollect [_ st (ipairs staged)] st.tmp))
          (values nil err))
        staged)))

(fn edit-files-locked [entries ?yield-fn]
  "Validate every entry against a fresh read, stage all results, then commit
   them together. Runs under with-files for every path."
  (let [validated []]
    (var error-msg nil)
    (each [i f (ipairs entries)]
      (when (not error-msg)
        (let [(v verr) (validate-edit-file f.path f.edits ?yield-fn)]
          (if verr
              (set error-msg (if f.label?
                                 (.. (or f.path (.. "file " (tostring i))) ": "
                                     verr)
                                 verr))
              (table.insert validated v)))))
    (if error-msg
        (util.err error-msg)
        (let [(staged stage-err) (stage-all! validated ?yield-fn)]
          (if (not staged)
              (util.err stage-err)
              (let [(summaries commit-err) (commit-staged! staged)]
                (if summaries
                    (util.ok (table.concat summaries "\n"))
                    (util.err commit-err))))))))

(fn run-edit-one [{: path : edits} ?yield-fn]
  (if (or (not path) (= path ""))
      (util.err "missing 'path'")
      (file-mutex.with-files [path]
        ?yield-fn
        #(edit-files-locked [{: path : edits}] ?yield-fn))))

(fn run-edit-batch [files ?yield-fn]
  (if (or (not files) (= (length files) 0))
      (util.err "missing 'files'")
      (let [entries []
            seen {}]
        (var error-msg nil)
        (each [i f (ipairs files)]
          (when (not error-msg)
            (let [path (?. f :path)
                  key (and path (not= path "") (file-mutex.canonical-path path))]
              (if (not key)
                  (set error-msg (.. "file " (tostring i) ": missing 'path'"))
                  (. seen key)
                  (set error-msg
                       (.. path
                           ": duplicate path in files batch; combine edits for the same file in one entry"))
                  (do
                    (tset seen key true)
                    (table.insert entries
                                  {: path :edits (?. f :edits) :label? true}))))))
        (if error-msg
            (util.err error-msg)
            ;; Hold every path's lock from the first read to the return: all
            ;; files are validated and staged, then renamed with no yield.
            (file-mutex.with-files (icollect [_ e (ipairs entries)] e.path)
              ?yield-fn
              #(edit-files-locked entries ?yield-fn))))))

(fn run-edit [args _ctx ?yield-fn]
  (let [has-single? (or (and args.path (not= args.path ""))
                        (not= args.edits nil))
        has-files? (not= args.files nil)]
    (if (and has-single? has-files?)
        (util.err "provide either 'path'/'edits' or 'files', not both")
        has-files?
        (run-edit-batch args.files ?yield-fn)
        (run-edit-one args ?yield-fn))))

{:name :edit
 :label "Edit"
 :snippet "Make exact-text replacements in one or more files"
 :description "Make exact-text replacements. Batch all known non-overlapping edits into one call: use one `edits` array for multiple changes in the same file, and use `files` for changes across multiple files. Do not emit separate edit calls for independent changes unless a later edit depends on seeing an earlier result. Single-file shape: {path, edits}. Batch shape: {files:[{path, edits}, ...]}, e.g. {files:[{path:\"a.fnl\", edits:[...]}, {path:\"b.fnl\", edits:[...]}]}. Each old_string must match uniquely in the original; multiple disjoint edits per file are applied to the original snapshot, not sequentially. Batch validation is all-or-nothing: if any file fails validation, no file is mutated. Every file is staged first and then replaced together, so a cancelled or failed edit leaves every file unchanged (a crash mid-commit can still leave a batch partly applied). If a file changed since it was read, the edit fails; re-read it and retry."
 :parameters {:type :object
              :properties {:path {:type :string
                                  :description "File path for single-file edits; mutually exclusive with files"}
                           :edits {:type :array
                                   :description "Replacements to apply to path. Put all known non-overlapping edits for this file in this one array."
                                   :items {:type :object
                                           :properties {:old_string {:type :string
                                                                     :description "Exact text to match (unique in file)"}
                                                        :new_string {:type :string
                                                                     :description "Replacement text"}}
                                           :required [:old_string :new_string]}}
                           :files {:type :array
                                   :description "Preferred for multi-file edits. Batch edits across files in one call; mutually exclusive with path/edits."
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
                                                                        :required [:old_string
                                                                                   :new_string]}}}
                                           :required [:path :edits]}}}}
 :execute run-edit}
