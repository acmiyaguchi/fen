;; Skill discovery — scan filesystem roots for Agent Skills (`SKILL.md`) and
;; render the available-skills prompt fragment.
;;
;; This intentionally mirrors the load-bearing parts of pi-mono's skills
;; discovery while staying POSIX/Lua-only:
;;   - `description` frontmatter is required; `name` is optional and falls
;;     back to the skill directory (or md filename for direct-root .md skills).
;;   - `disable-model-invocation: true` skills are discovered but omitted from
;;     the model prompt.
;;   - Discovery is recursive and stops at directories containing `SKILL.md`.
;;   - Dot-directories, node_modules, and paths matched by .gitignore,
;;     .ignore, or .fdignore are ignored.
;;   - Skills are deduped by canonical path and by skill name; first wins.

(local log (require :fen.util.log))
(local path (require :fen.util.path))
(local ignore (require :fen.extensions.skills.ignore))
(local ext-api (require :fen.core.extensions.api))

(local M {})

(fn config-dir []
  (path.config-dir :fen))

(fn trim [s]
  (-> (or s "") (string.gsub "^%s+" "") (string.gsub "%s+$" "")))

(fn strip-quotes [s]
  (let [m (or (string.match s "^\"(.*)\"$")
              (string.match s "^'(.*)'$"))]
    (or m s)))

(fn strip-md [name]
  (or (string.match name "^(.*)%.md$") name))

(fn parent-name-for-skill [skill-path]
  (if (= (path.basename skill-path) "SKILL.md")
      (path.basename (path.dirname skill-path))
      (strip-md (path.basename skill-path))))

(fn bool-value? [s]
  (let [v (string.lower (trim (tostring s)))]
    (or (= v "true") (= v "yes") (= v "1"))))

;; @doc fen.extensions.skills.dir-exists?
;; kind: data
;; signature: function
;; summary: Filesystem helper alias used by tests to stub directory existence during skill discovery.
;; tags: skills paths tests
(set M.dir-exists? path.dir-exists?)

;; @doc fen.extensions.skills.file-exists?
;; kind: data
;; signature: function
;; summary: Filesystem helper alias used by tests to stub skill file existence checks.
;; tags: skills paths tests
(set M.file-exists? path.file-exists?)

;; @doc fen.extensions.skills.realpath
;; kind: data
;; signature: function
;; summary: Filesystem helper alias used to canonicalize skill paths for deduplication and tests.
;; tags: skills paths tests
(set M.realpath path.realpath)

(fn list-children [dir]
  "Return immediate child names for `dir`. Empty for absent/unreadable dirs."
  (let [out []]
    (when (path.dir-exists? dir)
      (let [pipe (io.popen (.. "ls -1A " (path.shell-quote dir) " 2>/dev/null") :r)]
        (when pipe
          (each [line (pipe:lines)]
            (when (and line (not= line ""))
              (table.insert out line)))
          (pipe:close))))
    out))

(fn parse-frontmatter* [path fallback-name]
  "Return metadata from YAML frontmatter or nil when the skill is not
   model-invokable. `description` is required; `name` falls back to the
   directory/file name."
  (let [(f err) (io.open path :r)]
    (if (not f)
        (do (log.warn (.. "skills: cannot read " path ": " (tostring err)))
            nil)
        (let [first (f:read :*l)]
          (if (not= first "---")
              (do (f:close)
                  (log.warn (.. "skills: " path " missing frontmatter"))
                  nil)
              (let [meta {}]
                (var saw-end? false)
                (var lines-read 0)
                (while (and (not saw-end?) (< lines-read 64))
                  (let [line (f:read :*l)]
                    (set lines-read (+ lines-read 1))
                    (if (not line) (set saw-end? true)
                        (= line "---") (set saw-end? true)
                        (let [(k v) (string.match line "^([%w][%w%-_]*)%s*:%s*(.*)$")]
                          (when k
                            (tset meta k (strip-quotes (trim v))))))))
                (f:close)
                (let [name (or meta.name fallback-name)
                      description (trim meta.description)
                      disabled? (bool-value? (or (. meta "disable-model-invocation")
                                                 meta.disable_model_invocation
                                                 "false"))]
                  (if (or (not description) (= description ""))
                      (do (log.warn (.. "skills: " path " missing description"))
                          nil)
                      (do
                        (when (not (string.match name "^[A-Za-z0-9][A-Za-z0-9_-]*$"))
                          (log.warn (.. "skills: suspicious skill name '" name
                                         "' in " path)))
                        {: name : description
                         :disable-model-invocation? disabled?})))))))))

;; @doc fen.extensions.skills.parse-frontmatter
;; kind: function
;; signature: (parse-frontmatter path) -> SkillMeta|nil
;; summary: Parse a skill file's YAML frontmatter into invokable metadata using the path-derived fallback name.
;; tags: skills discovery frontmatter
(fn M.parse-frontmatter [path]
  (parse-frontmatter* path (parent-name-for-skill path)))

(fn add-skill [acc seen-paths seen-names path scope]
  (let [canonical (M.realpath path)]
    (when (not (. seen-paths canonical))
      (let [meta (parse-frontmatter* path (parent-name-for-skill path))]
        (when meta
          (if (. seen-names meta.name)
              (log.warn (.. "skills: duplicate skill name '" meta.name
                             "' at " path " skipped"))
              (do
                (tset seen-paths canonical true)
                (tset seen-names meta.name true)
                (table.insert acc {:name meta.name
                                   :description meta.description
                                   :path canonical
                                   :scope scope
                                   :disable-model-invocation?
                                   meta.disable-model-invocation?}))))))))

(fn ignored-child-dir? [target child rules]
  (or (= child "node_modules")
      (string.match child "^%.")
      (ignore.match? target true rules)))

(fn scan-skill-dir [dir scope acc seen-paths seen-names rules]
  (let [local-rules (ignore.with-dir rules dir)
        skill-md (.. dir "/SKILL.md")]
    (if (and (M.file-exists? skill-md)
             (not (ignore.match? skill-md false local-rules)))
        (add-skill acc seen-paths seen-names skill-md scope)
        (each [_ child (ipairs (list-children dir))]
          (let [child-path (.. dir "/" child)]
            (when (and (M.dir-exists? child-path)
                       (not (ignored-child-dir? child-path child local-rules)))
              (scan-skill-dir child-path scope acc seen-paths seen-names local-rules)))))))

(fn scan-root [root scope direct-md? acc seen-paths seen-names]
  (let [root (M.realpath root)]
    (when (M.dir-exists? root)
      (let [rules (ignore.load-chain root)]
        (when (not (ignore.match? root true rules))
          (let [local-rules (ignore.with-dir rules root)]
            (when direct-md?
              (each [_ child (ipairs (list-children root))]
                (let [child-path (.. root "/" child)]
                  (when (and (M.file-exists? child-path)
                             (string.match child "%.md$")
                             (not (ignore.match? child-path false local-rules)))
                    (add-skill acc seen-paths seen-names child-path scope)))))
            (each [_ child (ipairs (list-children root))]
              (let [child-path (.. root "/" child)]
                (when (and (M.dir-exists? child-path)
                           (not (ignored-child-dir? child-path child local-rules)))
                  (scan-skill-dir child-path scope acc seen-paths seen-names local-rules))))))))))

(fn ancestors [cwd stop-at-git?]
  "Return cwd ancestors root-to-leaf. When stop-at-git? is true and cwd is
   inside a git worktree, stop at the worktree root."
  (let [start (or (path.pwd-physical cwd) cwd)
        git-root (when stop-at-git?
                   (let [pipe (io.popen (.. "cd " (path.shell-quote start)
                                           " 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null") :r)]
                     (when pipe
                       (let [out (pipe:read :*l)]
                         (pipe:close)
                         out))))
        stop (or git-root "/")
        parts []]
    (var cur start)
    (var done? false)
    (while (not done?)
      (table.insert parts 1 cur)
      (if (or (= cur stop) (= cur "/"))
          (set done? true)
          (set cur (path.dirname cur))))
    parts))

(fn default-roots []
  (let [roots []]
    ;; fen's original roots stay first for backwards compatibility.
    (table.insert roots {:path (.. (config-dir) "/skills") :scope :user})
    (table.insert roots {:path "./.fen/skills" :scope :project})
    ;; pi/Agent Skills-compatible global roots.
    (table.insert roots {:path (.. (path.home) "/.pi/agent/skills") :scope :user})
    (table.insert roots {:path (.. (path.home) "/.agents/skills") :scope :user})
    ;; Common Claude/Codex compatibility roots.
    (table.insert roots {:path (.. (path.home) "/.claude/skills") :scope :user})
    (table.insert roots {:path (.. (path.home) "/.codex/skills") :scope :user})
    ;; Project/ancestor roots. .pi/skills supports direct root .md files;
    ;; .agents/.claude/.codex roots use SKILL.md directories only.
    (each [_ dir (ipairs (ancestors (path.cwd) true))]
      (table.insert roots {:path (.. dir "/.pi/skills")
                           :scope :project :direct-md? true})
      (table.insert roots {:path (.. dir "/.agents/skills") :scope :project})
      (table.insert roots {:path (.. dir "/.claude/skills") :scope :project})
      (table.insert roots {:path (.. dir "/.codex/skills") :scope :project}))
    roots))

(fn normalize-extra-path [p]
  (if (and p (not= p "")) {:path p :scope :cli :explicit? true} nil))

(fn discover-from-roots [roots]
  (let [acc []
        seen-paths {}
        seen-names {}]
    (each [_ root (ipairs (or roots []))]
      (when root.path
        (if (and root.explicit? (M.file-exists? root.path))
            (add-skill acc seen-paths seen-names root.path root.scope)
            (scan-root root.path root.scope root.direct-md? acc seen-paths seen-names))))
    acc))

;; @doc fen.extensions.skills.discover
;; kind: function
;; signature: (discover extra-paths?) -> [Skill]
;; summary: Scan default and explicit skill roots, respecting ignore files and deduplicating by canonical path and name.
;; tags: skills discovery roots
(fn M.discover [extra-paths]
  "Scan default roots plus explicit paths from --skill/--skills.
   Explicit file paths are accepted; directory paths are scanned as roots."
  (let [roots (default-roots)]
    (each [_ p (ipairs (or extra-paths []))]
      (let [r (normalize-extra-path p)]
        (when r (table.insert roots r))))
    (discover-from-roots roots)))

(fn xml-escape [s]
  (-> (tostring (or s ""))
      (string.gsub "&" "&amp;")
      (string.gsub "<" "&lt;")
      (string.gsub ">" "&gt;")))

;; @doc fen.extensions.skills.system-prompt-section
;; kind: function
;; signature: (system-prompt-section skills) -> string|nil
;; summary: Render discovered model-invokable skills as the XML prompt fragment consumed by the default prompt.
;; tags: skills prompt xml
(fn M.system-prompt-section [skills]
  "Render discovered model-invokable skills as pi/Agent Skills XML.
   Returns nil when no skills should be shown to the model."
  (let [visible []]
    (each [_ s (ipairs (or skills []))]
      (when (not s.disable-model-invocation?)
        (table.insert visible s)))
    (if (= (length visible) 0)
        nil
        (let [lines ["The following skills provide specialized instructions for specific tasks. Use the read tool to load a skill's file when the task matches its description. When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands."
                     ""
                     "<available_skills>"]]
          (each [_ s (ipairs visible)]
            (table.insert lines "  <skill>")
            (table.insert lines (.. "    <name>" (xml-escape s.name) "</name>"))
            (table.insert lines (.. "    <description>" (xml-escape s.description)
                                    "</description>"))
            (table.insert lines (.. "    <location>" (xml-escape s.path)
                                    "</location>"))
            (table.insert lines "  </skill>"))
          (table.insert lines "</available_skills>")
          (table.concat lines "\n")))))

;; @doc fen.extensions.skills.user-skills-dir
;; kind: function
;; signature: (user-skills-dir) -> string
;; summary: Return fen's user-level skills directory under the XDG configuration root.
;; tags: skills paths user
(set M.user-skills-dir (fn [] (.. (config-dir) "/skills")))

;; @doc fen.extensions.skills.project-skills-dir
;; kind: function
;; signature: (project-skills-dir) -> string
;; summary: Return fen's project-local skills directory path relative to the current workspace.
;; tags: skills paths project
(set M.project-skills-dir (fn [] "./.fen/skills"))
;; @doc fen.extensions.skills._discover-from-roots
;; kind: data
;; signature: function
;; summary: Test helper alias for scanning an explicit root list without loading default skill roots.
;; tags: skills discovery tests
(set M._discover-from-roots discover-from-roots)

;; @doc fen.extensions.skills._default-roots
;; kind: data
;; signature: function
;; summary: Test helper alias returning the ordered default user, project, and compatibility skill roots.
;; tags: skills discovery tests roots
(set M._default-roots default-roots)

;; @doc fen.extensions.skills._ancestors
;; kind: data
;; signature: function
;; summary: Test helper alias for the project-ancestor walker used when building default skill roots.
;; tags: skills discovery tests paths
(set M._ancestors ancestors)

(fn tool-has? [tools name]
  (var found? false)
  (each [_ t (ipairs (or tools []))]
    (when (= (tostring t.name) (tostring name))
      (set found? true)))
  found?)

(fn prompt-fragment [ctx]
  (when (tool-has? ctx.tools :read)
    (let [extra (or (?. ctx :opts :extra-skill-paths)
                    (?. ctx :opts :extra-skill-dirs)
                    [])
          found (M.discover extra)]
      (M.system-prompt-section found))))

(fn register! []
  (let [api (ext-api.make-api :skills)]
    (api.prompt prompt-fragment
                {:order 60
                 :id :available-skills
                 :title "Available skills"
                 :description "Discovered Agent Skills that the model can read on demand."}))
  true)

;; @doc fen.extensions.skills.register!
;; kind: data
;; signature: function
;; summary: Registration entrypoint alias for installing the available-skills prompt fragment.
;; tags: skills register prompt
(set M.register! register!)

(register!)

M
