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
(local bundled (require :fen.extensions.skills.bundled))
(local panel-state (require :fen.extensions.skills.state))

(local M {})

(fn config-dir []
  (path.config-dir :fen))

(fn data-dir []
  (path.data-dir :fen))

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

(fn mkdir-p [dir]
  (let [ok (os.execute (.. "mkdir -p " (path.shell-quote dir)))]
    (or (= ok true) (= ok 0))))

(fn read-all [p]
  (let [f (io.open p :r)]
    (when f
      (let [data (f:read :*a)]
        (f:close)
        data))))

(fn write-all-if-changed [p content]
  (when (not= (read-all p) content)
    (let [f (assert (io.open p :w))]
      (f:write content)
      (f:close))))

(var bundled-materialized? false)
(var bundled-materialized-root nil)

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

(fn rm-rf [p]
  (let [ok (os.execute (.. "rm -rf " (path.shell-quote p)))]
    (or (= ok true) (= ok 0))))

(fn prune-stale-bundled-skills [root specs]
  (let [keep {}]
    (each [_ spec (ipairs specs)]
      (tset keep spec.dir true))
    (each [_ child (ipairs (list-children root))]
      (let [child-path (.. root "/" child)]
        (when (and (M.dir-exists? child-path)
                   (not (. keep child)))
          (rm-rf child-path))))))

(fn materialize-bundled-skills []
  "Write built-in skills to XDG data storage once and return their root dir.
   Skills are exposed as real files so the model can load them with `read`."
  (var result nil)
  (when (not= (os.getenv :FEN_DISABLE_BUNDLED_SKILLS) "1")
    (if bundled-materialized?
        (set result bundled-materialized-root)
        (let [root (.. (data-dir) "/skills/bundled")
              specs (bundled.skills)]
          (set bundled-materialized? true)
          (if (not (mkdir-p root))
              (log.warn (.. "skills: cannot create bundled skills dir " root))
              (let [(ok? err)
                    (pcall
                      (fn []
                        (prune-stale-bundled-skills root specs)
                        (each [_ spec (ipairs specs)]
                          (let [dir (.. root "/" spec.dir)]
                            (if (not (mkdir-p dir))
                                (log.warn (.. "skills: cannot create bundled skill dir " dir))
                                (write-all-if-changed
                                  (.. dir "/" (or spec.file "SKILL.md"))
                                  spec.content))))))]
                (if ok?
                    (do (set bundled-materialized-root root)
                        (set result root))
                    (log.warn (.. "skills: cannot materialize bundled skills: "
                                  (tostring err)))))))))
  result)

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
    (let [builtin-root (materialize-bundled-skills)]
      (when builtin-root
        (table.insert roots {:path builtin-root :scope :builtin})))
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
;; @doc fen.extensions.skills.bundled-skills-dir
;; kind: function
;; signature: (bundled-skills-dir) -> string
;; summary: Return the XDG data directory where fen materializes built-in skills.
;; tags: skills paths builtin
(set M.bundled-skills-dir (fn [] (.. (data-dir) "/skills/bundled")))
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

(fn discover-for-ctx [ctx]
  (let [extra (or (?. ctx :opts :extra-skill-paths)
                  (?. ctx :opts :extra-skill-dirs)
                  [])]
    (M.discover extra)))

(fn fit [s w]
  (let [s (tostring (or s ""))]
    (if (> (length s) w)
        (if (> w 1) (.. (string.sub s 1 (- w 1)) "…") "…")
        s)))

(fn pad [s w]
  (let [s (fit s w)
        n (length s)]
    (.. s (string.rep " " (math.max 0 (- w n))))))

(fn visible? [skill]
  (not skill.disable-model-invocation?))

(fn skill-matches-filter? [skill filter]
  (or (= filter "")
      (= filter "all")
      (and (= filter "visible") (visible? skill))
      (and (= filter "hidden") (not (visible? skill)))
      (= (tostring skill.scope) filter)))

(fn M.skills-text [skills ?filter]
  "Render discovered skills as a human-readable table for /skills list."
  (let [filter (string.lower (trim (or ?filter "")))
        shown []
        visible-count (accumulate [n 0 _ s (ipairs (or skills []))]
                        (if (visible? s) (+ n 1) n))
        hidden-count (- (length (or skills [])) visible-count)]
    (each [_ skill (ipairs (or skills []))]
      (when (skill-matches-filter? skill filter)
        (table.insert shown skill)))
    (let [lines [(.. "# Skills (" (length shown) " shown, "
                     visible-count " visible, " hidden-count " hidden)")
                 ""]]
      (if (= (length shown) 0)
          (table.insert lines "No skills discovered.")
          (do
            (table.insert lines "```text")
            (table.insert lines (.. (pad "name" 28) " " (pad "scope" 8) " visibility  location"))
            (table.insert lines (.. (pad "----" 28) " " (pad "-----" 8) " ----------  --------"))
            (each [_ s (ipairs shown)]
              (table.insert lines
                (.. (pad s.name 28) " "
                    (pad (tostring s.scope) 8) " "
                    (pad (if (visible? s) "visible" "hidden") 10) "  "
                    (tostring s.path))))
            (table.insert lines "```")))
      (when (not= filter "")
        (table.insert lines "")
        (table.insert lines (.. "filter: `" filter "`")))
      (table.concat lines "\n"))))

(fn skill-items [skills]
  (let [items []]
    (each [_ s (ipairs (or skills []))]
      (table.insert items s))
    (table.sort items (fn [a b] (< (tostring a.name) (tostring b.name))))
    items))

(fn find-skill-by-name [skills name]
  (let [wanted (tostring (or name ""))]
    (var found nil)
    (each [_ s (ipairs (or skills []))]
      (when (and (not found) (= (tostring s.name) wanted))
        (set found s)))
    found))

(fn skill-choices [skills]
  (let [choices []]
    (each [_ s (ipairs (skill-items skills))]
      (table.insert choices
                    {:label (.. (tostring s.name)
                                "  " (tostring s.scope)
                                "  " (if (visible? s) "visible" "hidden"))
                     :value s
                     :description (or s.description s.path "")}))
    choices))

(fn dim [text] {:text text :style :dim})
(fn heading [text] {:text text :style :assistant})

(fn M.skill-detail-lines [skill]
  (let [lines [(heading (.. "Skill: " (tostring skill.name)))
               (dim (.. "scope: " (tostring skill.scope)))
               (dim (.. "visibility: " (if (visible? skill) "visible to model" "hidden from model")))]]
    (when skill.description
      (table.insert lines (dim (.. "description: " (tostring skill.description)))))
    (when skill.path
      (table.insert lines (dim (.. "path: " (tostring skill.path)))))
    (when skill.disable-model-invocation?
      (table.insert lines (dim "disable-model-invocation: true")))
    lines))

(fn skills-list-lines [skills]
  (let [items (skill-items skills)
        rows [(heading "Skills")]]
    (if (= (length items) 0)
        (table.insert rows (dim "  (none discovered)"))
        (do
          (table.insert rows (dim (.. "  " (pad "name" 28) "  " (pad "scope" 8) "  visibility  path")))
          (table.insert rows (dim (.. "  " (pad "----" 28) "  " (pad "-----" 8) "  ----------  ----")))
          (each [_ s (ipairs items)]
            (table.insert rows
                          (dim (.. "  " (pad s.name 28) "  "
                                   (pad (tostring s.scope) 8) "  "
                                   (pad (if (visible? s) "visible" "hidden") 10) "  "
                                   (tostring s.path)))))))
    rows))

(fn wrap-text [text width]
  (let [out []
        text (tostring (or text ""))
        width (math.max 1 width)]
    (var rest text)
    (while (> (length rest) width)
      (var cut width)
      (for [i width 1 -1]
        (when (and (= cut width) (= (string.sub rest i i) " "))
          (set cut i)))
      (if (<= cut 1)
          (do
            (table.insert out (string.sub rest 1 width))
            (set rest (string.sub rest (+ width 1))))
          (do
            (table.insert out (string.sub rest 1 (- cut 1)))
            (set rest (string.sub rest (+ cut 1))))))
    (table.insert out rest)
    out))

(fn box-top [w title]
  (let [head (.. "┌─ " title " ")
        head-cols (+ 4 (length title))
        fill-cols (math.max 0 (- w head-cols 1))]
    (.. head (string.rep "─" fill-cols) "┐")))

(fn box-bottom [w]
  (.. "└" (string.rep "─" (math.max 0 (- w 2))) "┘"))

(fn box-side [w text]
  (let [inner-w (math.max 0 (- w 4))
        text (or text "")
        n (length text)
        clipped (if (> n inner-w) (string.sub text 1 inner-w) text)
        pad (math.max 0 (- inner-w (length clipped)))]
    (.. "│ " clipped (string.rep " " pad) " │")))

(fn bordered-rows [w content ?title]
  (let [out [{:text (box-top w (or ?title "skills")) :style :dim}]
        inner-w (math.max 1 (- w 4))]
    (each [_ row (ipairs content)]
      (each [_ line (ipairs (wrap-text row.text inner-w))]
        (table.insert out {:text (box-side w line) :style row.style})))
    (table.insert out {:text (box-bottom w) :style :dim})
    out))

(fn selected-skill-rows [ctx]
  (let [skills (discover-for-ctx ctx)]
    (if panel-state.selected-name
        (let [skill (find-skill-by-name skills panel-state.selected-name)]
          (if skill
              (M.skill-detail-lines skill)
              [(heading "Skills")
               (dim (.. "selected skill not found: " (tostring panel-state.selected-name)))]))
        (skills-list-lines skills))))

(fn panel-title []
  (if panel-state.selected-name
      (.. "skill: " (tostring panel-state.selected-name))
      "skills"))

(fn panel-rows [ctx w]
  (let [now (os.time)]
    (when (or (not panel-state.cached-rows)
              (not= now panel-state.cached-at)
              (not= w panel-state.cached-w)
              (not= panel-state.selected-name panel-state.cached-selected-name))
      (set panel-state.cached-rows
           (bordered-rows w (selected-skill-rows ctx) (panel-title)))
      (set panel-state.cached-at now)
      (set panel-state.cached-w w)
      (set panel-state.cached-selected-name panel-state.selected-name))
    panel-state.cached-rows))

(fn invalidate-cache! []
  (set panel-state.cached-rows nil)
  (set panel-state.cached-at 0)
  (set panel-state.cached-w 0)
  (set panel-state.cached-selected-name nil))

(fn show-skill-panel [api ctx name]
  (let [skill (find-skill-by-name (discover-for-ctx ctx) name)]
    (if skill
        (do
          (api.emit {:type :dismiss})
          (set panel-state.selected-name (tostring skill.name))
          (set panel-state.visible? true)
          (invalidate-cache!)
          (api.emit {:type :redraw}))
        (api.emit {:type :error :error (.. "skill not found: " (tostring name))}))))

(fn show-skills-panel [api]
  (api.emit {:type :dismiss})
  (set panel-state.selected-name nil)
  (set panel-state.visible? true)
  (invalidate-cache!)
  (api.emit {:type :redraw}))

(fn pick-skill! [api ctx]
  (let [choices (skill-choices (discover-for-ctx ctx))]
    (if (= (length choices) 0)
        (api.emit {:type :info :text "no skills discovered"})
        (let [picked (api.ui.select {:label "skill details" :choices choices})]
          (when picked
            (let [skill (or picked.value picked)]
              (when skill.name
                (show-skill-panel api ctx skill.name))))))))

(fn panel-spec []
  {:name :skills
   :placement :above-input
   :order 58
   :height (fn [ctx]
             (if panel-state.visible?
                 (length (panel-rows ctx (or (?. ctx :w) 80)))
                 0))
   :render (fn [ctx]
             (if panel-state.visible?
                 (panel-rows ctx (or (?. ctx :w) 80))
                 []))})

(fn split-args [args]
  (let [out []]
    (each [arg (string.gmatch (tostring (or args "")) "%S+")]
      (table.insert out arg))
    out))

(fn tool-has? [tools name]
  (var found? false)
  (each [_ t (ipairs (or tools []))]
    (when (= (tostring t.name) (tostring name))
      (set found? true)))
  found?)

(fn prompt-fragment [ctx]
  (when (tool-has? ctx.tools :read)
    (M.system-prompt-section (discover-for-ctx ctx))))

(fn register! [api]
  (api.prompt prompt-fragment
              {:order 60
               :id :available-skills
               :title "Available skills"
               :description "Discovered Agent Skills that the model can read on demand."})
  (api.register :command
                {:name :skills
                 :order 65
                 :description "Pick a skill, show details, or list discovered Agent Skills"
                 :handler (fn [args ctx]
                            (let [parts (split-args args)
                                  first (. parts 1)]
                              (if (or (= first "list") (= first "all")
                                      (= first "visible") (= first "hidden")
                                      (= first "builtin") (= first "user")
                                      (= first "project") (= first "cli"))
                                  (api.emit {:type :assistant-text
                                             :text (M.skills-text (discover-for-ctx ctx)
                                                                  (if (or (= first "list") (= first "all"))
                                                                      ""
                                                                      first))})
                                  (and first (not= first ""))
                                  (show-skill-panel api ctx first)
                                  (pick-skill! api ctx))))})
  ;; @doc register-site:panel:skills
  ;; summary: Skill picker/detail panel backing the /skills command.
  ;; tags: panel skills commands
  (api.register :panel (panel-spec))
  (api.register :introspect
                {:name :discovered-skills
                 :description "Discovered Agent Skills, source scopes, paths, and model visibility"
                 :snapshot (fn [ctx]
                             (let [skills (discover-for-ctx ctx)]
                               {:count (length skills)
                                :visible-count (accumulate [n 0 _ s (ipairs skills)]
                                                 (if (visible? s) (+ n 1) n))
                                :panel {:visible? panel-state.visible?
                                        :selected-name panel-state.selected-name
                                        :cached-w panel-state.cached-w
                                        :cached-at panel-state.cached-at}
                                :skills skills}))})
  (api.on :dismiss
          (fn [ev]
            (when panel-state.visible?
              (set panel-state.visible? false)
              (invalidate-cache!)
              (when ev.announce?
                (api.emit {:type :info :text "skills panel: off"})))))
  true)

;; @doc fen.extensions.skills.register!
;; kind: data
;; signature: function
;; summary: Registration entrypoint alias for installing the available-skills prompt fragment.
;; tags: skills register prompt
(set M.register register!)
(set M.register! register!)

M
