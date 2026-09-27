{:name :decide
 :description "Experimental: opt-in advisory decisions from TypeSafe's Jev on OpenRouter's Decisions API, used by compaction, handoff hints, and busy-line routing."
 :entry-module :fen.extensions.decide
 :enabled-by-default false
 :reload-modules [:fen.extensions.decide.jev
                  :fen.extensions.decide.service
                  :fen.extensions.decide.compaction
                  :fen.extensions.decide.input
                  :fen.extensions.decide]
 :reload-exclude [:fen.extensions.decide.state]}
