(local path (require :fen.util.path))
(local memory (require :fen.extensions.claude_memory))
(local original {})
(local root (.. (os.tmpname) "-memory"))

(fn write-index [text]
  (path.ensure-dir! root)
  (let [f (assert (io.open (.. root "/MEMORY.md") :w))]
    (f:write text)
    (f:close)))

(describe "Claude memory interoperability"
          (before_each (fn []
                         (each [_ k (ipairs [:cwd
                                             :pwd-physical
                                             :file-exists?
                                             :dir-exists?
                                             :home])]
                           (tset original k (. path k)))))
          (after_each (fn []
                        (each [k v (pairs original)] (tset path k v))
                        (os.remove (.. root "/MEMORY.md"))
                        (os.execute (.. "rmdir " (path.shell-quote root)
                                        " 2>/dev/null"))))
          (it "includes only a bounded index, with provenance and inspection output"
              (fn []
                (write-index (string.rep "x" 9000))
                (let [r (memory.inspect {:directory root})
                      prompts []
                      commands []
                      emitted []]
                  (assert.is_true r.included?)
                  (assert.is_true r.truncated?)
                  (assert.are.equal 8192 (length r.text))
                  (memory.register {:settings {:extension (fn []
                                                            {:directory root})}
                                    :prompt (fn [f _opts]
                                              (table.insert prompts f))
                                    :register (fn [_kind spec]
                                                (table.insert commands spec))
                                    :emit (fn [ev] (table.insert emitted ev))})
                  (assert.truthy (string.find ((. prompts 1) {}) root 1 true))
                  (assert.truthy (string.find ((. prompts 1) {})
                                              "potentially stale" 1 true))
                  ((. commands 1 :handler) "" {})
                  (assert.truthy (string.find (. emitted 1 :text)
                                              "Included: yes" 1 true))
                  (assert.truthy (string.find (. emitted 1 :text)
                                              "Truncated: yes" 1 true))
                  (let [f (assert (io.open (.. root "/MEMORY.md") :r))]
                    (assert.are.equal 9000 (length (f:read :*a)))
                    (f:close)))))
          (it "diagnoses missing overrides and rejects relative paths"
              (fn []
                (assert.is_false (. (memory.inspect {:directory root})
                                    :included?))
                (assert.truthy (. (memory.inspect {:directory root}) :problem))
                (assert.truthy (. (memory.inspect {:directory "relative"})
                                  :problem))))
          (it "omits missing indexes quietly and rereads the next prompt"
              (fn []
                (let [prompts []
                      settings {:directory root}]
                  (memory.register {:settings {:extension (fn [] settings)}
                                    :prompt (fn [f _opts]
                                              (table.insert prompts f))
                                    :register (fn [_kind _spec] nil)
                                    :emit (fn [_ev] (error "unexpected notice"))})
                  (assert.is_nil ((. prompts 1) {}))
                  (write-index "A relevant lesson")
                  (assert.truthy (string.find ((. prompts 1) {})
                                              "A relevant lesson" 1 true))
                  (set settings.directory "/nonexistent/claude-memory-test")
                  (assert.is_nil ((. prompts 1) {})))))
          (it "does not split Unicode at the bound"
              (fn []
                (write-index (.. (string.rep "a" 8191) "é"))
                (let [r (memory.inspect {:directory root})]
                  (assert.is_true r.truncated?)
                  (assert.are.equal (string.rep "a" 8191) r.text))))
          (it "resolves a worktree by its own root, never its shared git directory"
              (fn []
                (set path.cwd (fn [] "/repo-worktree/sub"))
                (set path.pwd-physical (fn [p] p))
                (set path.home (fn [] "/home/test"))
                (set path.dir-exists?
                     (fn [_p]
                       false))
                (set path.file-exists? (fn [p] (= p "/repo-worktree/.git")))
                (assert.are.equal "/home/test/.claude/projects/-repo-worktree/memory"
                                  (. (memory.inspect) :directory)))))
