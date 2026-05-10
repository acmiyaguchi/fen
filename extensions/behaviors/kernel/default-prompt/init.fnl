;; First-party default prompt policy extension.
;;
;; Owns fen's built-in prompt sections: tool list, guidelines, body,
;; project context, and date/cwd footer. core.prompt only assembles ordered
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

;; @doc fen.extensions.default_prompt.tool-list-section
;; kind: function
;; signature: (tool-list-section tools) -> string|nil
;; summary: Render the available-tools prompt section from registered tool snippets, omitting the section when none are present.
;; tags: prompt default tools
(fn M.tool-list-section [tools]
  (let [lines []]
    (each [_ t (ipairs (or tools []))]
      (when t.snippet
        (table.insert lines (.. "- " (tostring t.name) ": " t.snippet))))
    (when (> (length lines) 0)
      (table.insert lines 1 "Available tools:")
      (table.concat lines "\n"))))

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
        (table.insert lines "- Prefer grep/find/ls tools over bash for file exploration when practical.")
        has-bash?
        (table.insert lines "- Use bash for file operations like ls, grep, and find."))
    (when (tool-has? tools :agent_state)
      (table.insert lines "- Use agent_state when you need to inspect your own running state (prior messages, available tools, model/provider metadata, usage, or session context). Prefer narrow read-only queries."))
    (when (or (tool-has? tools :read) (tool-has? tools :edit))
      (table.insert lines "- Batch tool use when possible: use read with `paths` for multiple known files, use one edit `edits` array for same-file replacements, and use edit `files` for multi-file replacements. Batch edits are validated together and are safer than separate calls."))
    (table.insert lines "- When multiple tool calls are independent — reading several files, running several greps, or inspecting unrelated paths — emit them as multiple tool calls in one response rather than one per turn. Do not batch when one call's output feeds the next. Do not split independent same-file edits across separate edit calls; combine them or retry as one batched edit if asked.")
    (table.insert lines "- Be concise in your responses.")
    (table.insert lines "- Show file paths clearly when working with files.")
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
  (api.prompt (fn [ctx] (M.tool-list-section ctx.tools))
              {:order 10
               :id :tool-list
               :title "Available tools"
               :description "Lists registered tools and short usage snippets."})
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
