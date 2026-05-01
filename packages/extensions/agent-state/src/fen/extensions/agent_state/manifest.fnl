{:name :agent_state
 :description "Read-only introspection tool for the running agent"
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.agent_state
 :reload-modules [:fen.extensions.agent_state.tool
                  :fen.extensions.agent_state]}
