{:name :subagent
 :description "Delegate a task to a child fen agent with isolated context"
 :entry-module :fen.extensions.subagent
 :reload-modules [:fen.extensions.subagent.bundled
                  :fen.extensions.subagent.discover
                  :fen.extensions.subagent.channel
                  :fen.extensions.subagent.runs
                  :fen.extensions.subagent.worktrees
                  :fen.extensions.subagent]
 :reload-exclude [:fen.extensions.subagent.state]}
