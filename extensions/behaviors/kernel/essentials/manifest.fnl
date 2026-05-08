{:name :essentials
 :description "Essential fen slash commands: help and model selection."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.essentials
 :reload-modules [:fen.extensions.essentials.commands.help
                  :fen.extensions.essentials.commands.model
                  :fen.extensions.essentials]}
