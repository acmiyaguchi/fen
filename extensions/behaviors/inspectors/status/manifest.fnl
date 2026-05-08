{:name :status
 :description "Runtime status inspector: /status command and status panel."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.status
 :reload-modules [:fen.extensions.status.util
                  :fen.extensions.status.commands.status
                  :fen.extensions.status]}
