;; Agent discovery for the subagent extension.
;;
;; Agents are markdown-with-frontmatter files, mirroring how skills are
;; discovered. Roots, in precedence order (project beats user):
;;   - ./.fen/agents/*.md                       (project)
;;   - ${XDG_CONFIG_HOME:-~/.config}/fen/agents/*.md  (user)
;; The frontmatter carries name/description and optional model/provider/
;; timeout-seconds; the body is the child agent's system prompt.

(local path (require :fen.util.path))
(local frontmatter (require :fen.util.frontmatter))
(local log (require :fen.util.log))

(local M {})

(fn user-root []
  (.. (path.config-dir :fen) "/agents"))

(fn project-root []
  "./.fen/agents")

;; @doc fen.extensions.subagent.discover.roots
;; kind: function
;; signature: (roots) -> [{:path :scope}]
;; summary: Agent discovery roots in precedence order (project before user).
;; tags: subagent discovery roots
(fn M.roots []
  [{:path (project-root) :scope :project}
   {:path (user-root) :scope :user}])

(fn blank->nil [s]
  (if (and s (not= s "")) s nil))

(fn parse-timeout [raw file]
  "Coerce a frontmatter timeout to a positive number, warning and falling back
   to the default (nil) for non-numeric or non-positive values."
  (let [trimmed (blank->nil raw)]
    (when trimmed
      (let [n (tonumber trimmed)]
        (if (and n (> n 0))
            n
            (do (log.warn (.. "subagent: ignoring invalid timeout-seconds '"
                              (tostring raw) "' in " file))
                nil))))))

(fn parse-agent [file fallback-name]
  ;; The body is the child's system prompt, so request it (?with-body true).
  (let [(fields body) (frontmatter.parse-file file true)]
    (when fields
      {:name (or fields.name fallback-name)
       :description (or fields.description "")
       :model (blank->nil fields.model)
       :provider (blank->nil fields.provider)
       :timeout-seconds (parse-timeout (or fields.timeout-seconds
                                           fields.timeout_seconds)
                                       file)
       :body (or body "")})))

;; @doc fen.extensions.subagent.discover.find-agent
;; kind: function
;; signature: (find-agent name) -> AgentConfig|nil
;; summary: Resolve an agent definition by name, project roots winning over user roots. Returns {:name :description :model :provider :timeout-seconds :body} or nil.
;; tags: subagent discovery
(fn M.find-agent [name]
  (var found nil)
  (each [_ root (ipairs (M.roots)) &until found]
    (set found (parse-agent (.. root.path "/" name ".md") name)))
  found)

(fn list-md [dir]
  "Return *.md filenames directly under DIR (non-recursive), or [] when the
   directory does not exist."
  (let [out []]
    (each [_ name (ipairs (path.list-dir dir))]
      (when (string.match name "%.md$")
        (table.insert out name)))
    out))

;; @doc fen.extensions.subagent.discover.list
;; kind: function
;; signature: (list) -> [AgentConfig]
;; summary: All discovered agents across roots, deduped by name (project wins). Used by tests and a future /agents command.
;; tags: subagent discovery
(fn M.list []
  (let [seen {}
        agents []]
    (each [_ root (ipairs (M.roots))]
      (each [_ fname (ipairs (list-md root.path))]
        (let [name (string.match fname "^(.*)%.md$")]
          (when (and name (not (. seen name)))
            (let [cfg (parse-agent (.. root.path "/" fname) name)]
              (when cfg
                (tset seen name true)
                (set cfg.scope root.scope)
                (table.insert agents cfg)))))))
    agents))

M
