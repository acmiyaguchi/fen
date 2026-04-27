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
;;   - Dot-directories and node_modules are ignored.
;;   - Skills are deduped by canonical path and by skill name; first wins.

(local log (require :util.log))

(local M {})

(fn home []
  (or (os.getenv :HOME) "/tmp"))

(fn config-dir []
  (let [xdg (os.getenv :XDG_CONFIG_HOME)]
    (if (and xdg (not= xdg ""))
        (.. xdg "/agent-fennel")
        (.. (home) "/.config/agent-fennel"))))

(fn shell-quote [s]
  (.. "'" (string.gsub (tostring s) "'" "'\\''") "'"))

(fn trim [s]
  (-> (or s "") (string.gsub "^%s+" "") (string.gsub "%s+$" "")))

(fn strip-quotes [s]
  (let [m (or (string.match s "^\"(.*)\"$")
              (string.match s "^'(.*)'$"))]
    (or m s)))

(fn basename [path]
  (or (string.match path "([^/]+)$") path))

(fn dirname [path]
  (let [d (string.match path "^(.*)/[^/]+$")]
    (if (not d) "."
        (= d "") "/"
        d)))

(fn strip-md [name]
  (or (string.match name "^(.*)%.md$") name))

(fn parent-name-for-skill [path]
  (if (= (basename path) "SKILL.md")
      (basename (dirname path))
      (strip-md (basename path))))

(fn bool-value? [s]
  (let [v (string.lower (trim (tostring s)))]
    (or (= v "true") (= v "yes") (= v "1"))))

(fn path-exists? [path kind]
  (let [test-flag (if (= kind :dir) "-d" "-f")
        pipe (io.popen (.. "test " test-flag " " (shell-quote path)
                            " && echo y") :r)]
    (if (not pipe)
        false
        (let [out (pipe:read :*l)]
          (pipe:close)
          (= out "y")))))

(fn M.dir-exists? [path] (path-exists? path :dir))
(fn M.file-exists? [path] (path-exists? path :file))

(fn pwd-physical [dir]
  (let [pipe (io.popen (.. "cd " (shell-quote dir) " 2>/dev/null && pwd -P") :r)]
    (when pipe
      (let [out (pipe:read :*l)]
        (pipe:close)
        out))))

(fn M.realpath [path]
  "Best-effort canonical path for existing files/directories."
  (let [dir (dirname path)
        base (basename path)
        real-dir (pwd-physical dir)]
    (if real-dir (.. real-dir "/" base) path)))

(fn list-children [path]
  "Return immediate child names for `path`. Empty for absent/unreadable dirs."
  (let [out []]
    (when (M.dir-exists? path)
      (let [pipe (io.popen (.. "ls -1A " (shell-quote path) " 2>/dev/null") :r)]
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

(fn scan-skill-dir [dir scope acc seen-paths seen-names]
  (let [skill-md (.. dir "/SKILL.md")]
    (if (M.file-exists? skill-md)
        (add-skill acc seen-paths seen-names skill-md scope)
        (each [_ child (ipairs (list-children dir))]
          (let [path (.. dir "/" child)]
            (when (and (M.dir-exists? path)
                       (not= child "node_modules")
                       (not (string.match child "^%.")))
              (scan-skill-dir path scope acc seen-paths seen-names)))))))

(fn scan-root [root scope direct-md? acc seen-paths seen-names]
  (when (M.dir-exists? root)
    (when direct-md?
      (each [_ child (ipairs (list-children root))]
        (let [path (.. root "/" child)]
          (when (and (M.file-exists? path) (string.match child "%.md$"))
            (add-skill acc seen-paths seen-names path scope)))))
    (each [_ child (ipairs (list-children root))]
      (let [path (.. root "/" child)]
        (when (and (M.dir-exists? path)
                   (not= child "node_modules")
                   (not (string.match child "^%.")))
          (scan-skill-dir path scope acc seen-paths seen-names))))))

(fn ancestors [cwd stop-at-git?]
  "Return cwd ancestors root-to-leaf. When stop-at-git? is true and cwd is
   inside a git worktree, stop at the worktree root."
  (let [start (or (pwd-physical cwd) cwd)
        git-root (when stop-at-git?
                   (let [pipe (io.popen (.. "cd " (shell-quote start)
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
          (set cur (dirname cur))))
    parts))

(fn cwd []
  (or (os.getenv :PWD) (pwd-physical ".") "."))

(fn default-roots []
  (let [roots []]
    ;; agent-fennel's original roots stay first for backwards compatibility.
    (table.insert roots {:path (.. (config-dir) "/skills") :scope :user})
    (table.insert roots {:path "./.agent-fennel/skills" :scope :project})
    ;; pi/Agent Skills-compatible global roots.
    (table.insert roots {:path (.. (home) "/.pi/agent/skills") :scope :user})
    (table.insert roots {:path (.. (home) "/.agents/skills") :scope :user})
    ;; Common Claude/Codex compatibility roots.
    (table.insert roots {:path (.. (home) "/.claude/skills") :scope :user})
    (table.insert roots {:path (.. (home) "/.codex/skills") :scope :user})
    ;; Project/ancestor roots. .pi/skills supports direct root .md files;
    ;; .agents/.claude/.codex roots use SKILL.md directories only.
    (each [_ dir (ipairs (ancestors (cwd) true))]
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

(set M.user-skills-dir (fn [] (.. (config-dir) "/skills")))
(set M.project-skills-dir (fn [] "./.agent-fennel/skills"))
(set M._discover-from-roots discover-from-roots)
(set M._default-roots default-roots)
(set M._ancestors ancestors)

M
