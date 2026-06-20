{:name :subagent
 :description "Delegate a task to a child fen agent with isolated context"
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.subagent
 :reload-modules [:fen.extensions.subagent.discover
                  :fen.extensions.subagent]}
