;; System prompt assembly.
;;
;; Builds a pi-mono-shaped prompt from a ResourceLoader snapshot plus the
;; registered tools. Kept separate from main.fnl so the prompt shape can be
;; unit-tested without starting the CLI.

(local skills (require :core.skills))

(local M {})

(local DEFAULT-PROMPT
  "You are agent-fennel, a concise AI coding assistant. Help the user by reading files, running commands, editing code, and explaining changes clearly.")

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

(fn current-date []
  (os.date "%Y-%m-%d"))

(fn M.build [opts loader tools]
  (let [opts (or opts {})
        loader (or loader {})
        parts []
        tool-list (M.tool-list-section tools)
        guidelines (M.guidelines-section tools)
        body (or opts.system
                 (?. loader :system-md :content)
                 DEFAULT-PROMPT)
        append-text (?. loader :append-system-md :content)
        context-text (M.context-section loader.context-files)
        skill-text (when (tool-has? tools :read)
                     (skills.system-prompt-section loader.skills))
        date (or opts.current-date (current-date))
        cwd (or loader.cwd ".")]
    (when tool-list (table.insert parts tool-list))
    (when guidelines (table.insert parts guidelines))
    (when body (table.insert parts body))
    (when append-text (table.insert parts append-text))
    (when context-text (table.insert parts context-text))
    (when skill-text (table.insert parts skill-text))
    (table.insert parts (.. "Current date: " date))
    (table.insert parts (.. "Current working directory: " cwd))
    (table.concat parts "\n\n")))

(set M.default-prompt DEFAULT-PROMPT)

M
