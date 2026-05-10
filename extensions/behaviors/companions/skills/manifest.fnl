{:name :skills
 :description "Agent Skills discovery and prompt fragment"
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.skills
 :reload-modules [:fen.extensions.skills.ignore
                  :fen.extensions.skills.bundled
                  :fen.extensions.skills]
 :reload-exclude [:fen.extensions.skills.state]}
