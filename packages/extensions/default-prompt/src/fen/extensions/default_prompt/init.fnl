;; First-party default prompt policy extension.
;;
;; Owns fen's built-in prompt sections: tool list, guidelines, body,
;; project context, and date/cwd footer. core.prompt only assembles ordered
;; fragments.

(local extensions (require :fen.core.extensions))

(local OWNER :default_prompt)
(local M {})

(local DEFAULT-PROMPT
  "You are fen, a concise AI coding assistant. Help the user by reading files, running commands, editing code, and explaining changes clearly.")

(fn tool-has? [tools name]
  (var found? false)
  (each [_ t (ipairs (or tools []))]
    (when (= (tostring t.name) (tostring name))
      (set found? true)))
  found?)

(fn M.tool-list-section [tools]
  (let [lines []]
    (each [_ t (ipairs (or tools []))]
      (when t.snippet
        (table.insert lines (.. "- " (tostring t.name) ": " t.snippet))))
    (when (> (length lines) 0)
      (table.insert lines 1 "Available tools:")
      (table.concat lines "\n"))))

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
      (table.insert lines "- When reading or editing multiple independent files, prefer one batched read/edit call over several single-path calls."))
    (table.insert lines "- When multiple tool calls are independent — reading several files, running several greps, or inspecting unrelated paths — emit them as multiple tool calls in one response rather than one per turn. Do not batch when one call's output feeds the next. For edits to the same file, prefer one edit call with multiple edits rather than separate edit calls.")
    (table.insert lines "- Be concise in your responses.")
    (table.insert lines "- Show file paths clearly when working with files.")
    (table.concat lines "\n")))

(fn M.context-section [context-files]
  (when (and context-files (> (length context-files) 0))
    (let [parts ["# Project Context"]]
      (each [_ f (ipairs context-files)]
        (when f.content
          (table.insert parts (.. "## " f.path "\n\n" f.content))))
      (table.concat parts "\n\n"))))

(fn body-section [ctx]
  (or (?. ctx :opts :system)
      (?. ctx :loader :system-md :content)
      DEFAULT-PROMPT))

(fn append-section [ctx]
  (?. ctx :loader :append-system-md :content))

(fn context-fragment [ctx]
  (M.context-section (?. ctx :loader :context-files)))

(fn register! []
  (extensions.unregister-by-owner OWNER)
  (local api (extensions.make-api OWNER))
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
  (api.prompt (fn [ctx] (.. "Current date: " ctx.current-date))
              {:order 100
               :id :current-date
               :title "Current date"
               :description "The date supplied to the model for temporal context."})
  (api.prompt (fn [ctx] (.. "Current working directory: " ctx.cwd))
              {:order 110
               :id :current-working-directory
               :title "Current working directory"
               :description "The process working directory for path-sensitive tasks."})
  true)

(set M.default-prompt DEFAULT-PROMPT)
(set M.register! register!)

(register!)

M
