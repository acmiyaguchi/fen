;; First-party default prompt policy extension.
;;
;; Owns fen's built-in prompt sections: guidelines, body, project context,
;; and date/cwd footer. core.prompt only assembles ordered
;; fragments.

(local path (require :fen.util.path))
(local resources (require :fen.extensions.default_prompt.resources))

(local OWNER :default_prompt)
(local M {})

(local DEFAULT-PROMPT
  "You are fen, a concise AI coding assistant. Help the user by reading files, running commands, editing code, and explaining changes clearly.")

(var loader nil)

(fn current-loader []
  (when (= loader nil)
    (set loader (resources.make {})))
  loader)

(fn tool-has? [tools name]
  (var found? false)
  (each [_ t (ipairs (or tools []))]
    (when (= (tostring t.name) (tostring name))
      (set found? true)))
  found?)

;; @doc fen.extensions.default_prompt.guidelines-section
;; kind: function
;; signature: (guidelines-section tools) -> string
;; summary: Render built-in model guidance tailored to the currently available file, bash, read/edit, and agent_state tools.
;; tags: prompt default guidelines tools
(fn M.guidelines-section [tools]
  (let [lines ["Guidelines:"]
        has-bash? (tool-has? tools :bash)
        has-file-tool? (or (tool-has? tools :grep)
                           (tool-has? tools :find)
                           (tool-has? tools :ls))]
    (if (and has-bash? has-file-tool?)
        (table.insert lines "- Prefer dedicated file tools over shell commands when practical.")
        has-bash?
        (table.insert lines "- Use bash for file operations."))
    (when (tool-has? tools :tool_search)
      (table.insert lines "- Specialized extension tools are available through tool_search; activate one when its capability matches the task."))
    (when (and (tool-has? tools :agent_state)
               (not (tool-has? tools :tool_search)))
      (table.insert lines "- Use agent_state for narrow inspection of the running agent."))
    (when (or (tool-has? tools :read) (tool-has? tools :edit))
      (table.insert lines "- Batch independent tool calls and related file reads or edits."))
    (table.insert lines "- Keep user-facing output brief. Do not restate requests, narrate routine work, or repeat tool output. For completed work, report the outcome, key files, validation, and material caveats; expand only when asked or necessary.")
    (table.concat lines "\n")))

;; @doc fen.extensions.default_prompt.context-section
;; kind: function
;; signature: (context-section context-files) -> string|nil
;; summary: Render loaded project context files as titled prompt sections for the default system prompt.
;; tags: prompt default context
(fn M.context-section [context-files]
  (when (and context-files (> (length context-files) 0))
    (let [parts ["# Project Context"]]
      (each [_ f (ipairs context-files)]
        (when f.content
          (table.insert parts (.. "## " f.path "\n\n" f.content))))
      (table.concat parts "\n\n"))))

(fn body-section [ctx]
  (let [r (current-loader)]
    (or (?. ctx :opts :system)
        (?. r :system-md :content)
        DEFAULT-PROMPT)))

(fn append-section [_ctx]
  (?. (current-loader) :append-system-md :content))

(fn context-fragment [_ctx]
  (M.context-section (?. (current-loader) :context-files)))

(fn current-date-section [ctx]
  (.. "Current date: " (or (?. ctx :opts :current-date)
                           (os.date "%Y-%m-%d"))))

(fn cwd-section [_ctx]
  (.. "Current working directory: " (path.cwd)))

(fn register! [api]
  (set loader (resources.make {}))
  (api.prompt (fn [ctx] (M.guidelines-section ctx.tools))
              {:order 20
               :id :guidelines
               :title "Guidelines"
               :description "General tool-use and response-style guidance."})
  (api.prompt body-section
              {:order 30
               :id :body
               :title "Base system prompt"
               :description "Main assistant identity, from CLI/system resource or the built-in default."})
  (api.prompt append-section
              {:order 40
               :id :append-system
               :title "Appended system prompt"
               :description "Optional APPEND_SYSTEM.md overlay content."})
  (api.prompt context-fragment
              {:order 50
               :id :project-context
               :title "Project context"
               :description "Loaded project/user context files such as CLAUDE.md or AGENTS.md."})
  (api.prompt current-date-section
              {:order 100
               :id :current-date
               :title "Current date"
               :description "The date supplied to the model for temporal context."})
  (api.prompt cwd-section
              {:order 110
               :id :current-working-directory
               :title "Current working directory"
               :description "The process working directory for path-sensitive tasks."})
  true)

;; @doc fen.extensions.default_prompt.default-prompt
;; kind: data
;; signature: string
;; summary: Built-in fallback system prompt used when no SYSTEM.md or CLI system override is available.
;; tags: prompt default data
(set M.default-prompt DEFAULT-PROMPT)

;; @doc fen.extensions.default_prompt.register!
;; kind: data
;; signature: function
;; summary: Registration entrypoint alias for installing the default prompt fragments into the extension registry.
;; tags: prompt default register
(set M.register register!)
(set M.register! register!)

;; @doc fen.extensions.default_prompt.current-loader
;; kind: data
;; signature: function
;; summary: Loader accessor alias returning the cached default-prompt resource loader, creating it on first use.
;; tags: prompt default resources
(set M.current-loader current-loader)

M
