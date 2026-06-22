{:name :simplify
 :description "Simplify companion: fan out subagent reviewers over the diff and apply quality cleanups."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.simplify
 :reload-modules [:fen.extensions.simplify]
 :reload-exclude [:fen.extensions.simplify.state]}
