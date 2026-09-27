{:name :decide
 :description "Opt-in advisory decision service backed by TypeSafe's Jev on OpenRouter's Decisions API."
 :entry-module :fen.extensions.decide
 :enabled-by-default false
 :reload-modules [:fen.extensions.decide.jev
                  :fen.extensions.decide.service
                  :fen.extensions.decide]
 :reload-exclude [:fen.extensions.decide.state]}
