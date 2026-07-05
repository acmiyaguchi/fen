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
(local text (require :fen.util.text))
(local log (require :fen.util.log))

(local M {})

(local blank->nil text.blank->nil)

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

(fn invalid [file reason]
  {:file file :reason reason})

(fn parse-agent [file ?with-body]
  ;; find-agent needs the body (it becomes the child's system prompt); list only
  ;; wants the header fields, so it leaves ?with-body off to skip the body read.
  ;; Returns (values cfg nil) on success, (values nil err) when FILE exists but
  ;; is not a usable agent definition, and nil when FILE is absent.
  (when (path.file-exists? file)
    (let [(fields body-or-reason err) (frontmatter.parse-file file ?with-body)]
      (if (not fields)
          (values nil (invalid file
                               (if (= body-or-reason :unreadable)
                                   (.. "cannot read file: " (tostring err))
                                   "missing frontmatter")))
          (not (blank->nil fields.name))
          (values nil (invalid file "missing required frontmatter field `name`"))
          (values {:name fields.name
                   :description (or fields.description "")
                   :model (blank->nil fields.model)
                   :provider (blank->nil fields.provider)
                   :timeout-seconds (parse-timeout (or fields.timeout-seconds
                                                       fields.timeout_seconds)
                                                   file)
                   :body (or body-or-reason "")}
                  nil)))))

;; @doc fen.extensions.subagent.discover.find-agent
;; kind: function
;; signature: (find-agent name) -> (values AgentConfig nil) | (values nil AgentError) | nil
;; summary: Resolve an agent definition by filename, project roots winning over user roots. Returns cfg, an invalid-definition error for the highest-precedence present candidate, or nil for no matching file.
;; tags: subagent discovery
(fn M.find-agent [name]
  (var found nil)
  (var found-err nil)
  (each [_ root (ipairs (M.roots)) &until (or found found-err)]
    (let [(cfg err) (parse-agent (.. root.path "/" name ".md") true)]
      (set found cfg)
      (set found-err err)))
  (values found found-err))

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
            (let [(cfg err) (parse-agent (.. root.path "/" fname))]
              (if cfg
                  (do
                    (tset seen name true)
                    (set cfg.scope root.scope)
                    (table.insert agents cfg))
                  err
                  (log.warn (.. "subagent: invalid agent definition " err.file
                                ": " err.reason))))))))
    agents))

M
