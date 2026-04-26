;; Skill discovery — scan filesystem roots for `SKILL.md` and inject the
;; result into the system prompt as a list of available playbooks.
;;
;; Mirrors the floor of pi-mono's skills.ts (model-invocation only):
;;   - A skill is a directory containing SKILL.md with YAML frontmatter
;;     (`name`, `description`).
;;   - Discovery roots, in order:
;;       1. ~/.config/agent-fennel/skills/  (user scope)
;;       2. ./.agent-fennel/skills/         (project scope)
;;       3. Any extra dirs passed via --skills <dir>
;;   - We do not recurse past a SKILL.md root.
;;
;; Skipped vs pi-mono: nested .md children, project/user/path scope tagging
;; beyond a debug field, `disable-model-invocation` flag, theme/extension
;; sibling discovery.

(local log (require :util.log))

(fn home []
  (or (os.getenv :HOME) "/tmp"))

(fn config-dir []
  (let [xdg (os.getenv :XDG_CONFIG_HOME)]
    (if (and xdg (not= xdg ""))
        (.. xdg "/agent-fennel")
        (.. (home) "/.config/agent-fennel"))))

(fn user-skills-dir [] (.. (config-dir) "/skills"))
(fn project-skills-dir [] "./.agent-fennel/skills")

(fn shell-quote [s]
  (.. "'" (string.gsub s "'" "'\\''") "'"))

(fn dir-exists? [path]
  (let [pipe (io.popen (.. "test -d " (shell-quote path) " && echo y") :r)]
    (if (not pipe)
        false
        (let [out (pipe:read :*l)]
          (pipe:close)
          (= out :y)))))

(fn file-exists? [path]
  (let [pipe (io.popen (.. "test -f " (shell-quote path) " && echo y") :r)]
    (if (not pipe)
        false
        (let [out (pipe:read :*l)]
          (pipe:close)
          (= out :y)))))

(fn list-subdirs [path]
  "Return the immediate subdirectory names under `path`. Empty list if path
   doesn't exist or is unreadable."
  (let [out []]
    (when (dir-exists? path)
      (let [pipe (io.popen (.. "ls -1 " (shell-quote path) " 2>/dev/null") :r)]
        (when pipe
          (each [line (pipe:lines)]
            (when (and line (not= line "")
                       (dir-exists? (.. path "/" line)))
              (table.insert out line)))
          (pipe:close))))
    out))

;; ----------------------------------------------------------------
;; Frontmatter parser
;; ----------------------------------------------------------------

(fn strip-quotes [s]
  (let [m (or (string.match s "^\"(.*)\"$")
              (string.match s "^'(.*)'$"))]
    (or m s)))

(fn trim [s]
  (-> s (string.gsub "^%s+" "") (string.gsub "%s+$" "")))

(fn parse-frontmatter [path]
  "Return {:name :description} parsed from the YAML frontmatter of `path`,
   or nil if the file is missing/has no frontmatter/lacks both fields."
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
                        (let [(k v) (string.match line "^([%w][%w%-_]*)%s*:%s*(.+)$")]
                          (when k
                            (tset meta k (strip-quotes (trim v))))))))
                (f:close)
                (if (and meta.name meta.description)
                    {:name meta.name :description meta.description}
                    (do (log.warn (.. "skills: " path
                                       " missing name or description"))
                        nil))))))))

;; ----------------------------------------------------------------
;; Discovery
;; ----------------------------------------------------------------

(fn discover-in-root [root scope acc seen]
  (each [_ name (ipairs (list-subdirs root))]
    (let [skill-md (.. root "/" name "/SKILL.md")]
      (when (and (file-exists? skill-md) (not (. seen skill-md)))
        (let [meta (parse-frontmatter skill-md)]
          (when meta
            (tset seen skill-md true)
            (table.insert acc {:name meta.name
                               :description meta.description
                               :path skill-md
                               : scope})))))))

(fn discover [extra-dirs]
  "Scan all configured roots, return `[{:name :description :path :scope}]`.
   `extra-dirs` is an optional list of additional roots (lower priority,
   tagged scope=:cli)."
  (let [acc []
        seen {}]
    (discover-in-root (user-skills-dir) :user acc seen)
    (discover-in-root (project-skills-dir) :project acc seen)
    (each [_ d (ipairs (or extra-dirs []))]
      (discover-in-root d :cli acc seen))
    acc))

;; ----------------------------------------------------------------
;; System-prompt formatting
;; ----------------------------------------------------------------

(fn system-prompt-section [skills]
  "Render the list of discovered skills into a system-prompt fragment.
   Returns nil when `skills` is empty so the caller can decide whether to
   inject anything."
  (if (or (not skills) (= (length skills) 0))
      nil
      (let [lines ["Available skills:"]]
        (each [_ s (ipairs skills)]
          (table.insert lines
            (string.format "- %s (%s): %s" s.name s.path s.description)))
        (table.insert lines "")
        (table.insert lines
          "To use a skill, read its SKILL.md path with the `read` tool and follow the playbook it contains.")
        (table.concat lines "\n"))))

{: discover : system-prompt-section
 : parse-frontmatter
 : user-skills-dir : project-skills-dir}
