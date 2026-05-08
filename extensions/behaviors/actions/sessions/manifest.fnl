{:name :sessions
 :description "Conversation and session lifecycle commands: new, reload, sessions, resume, and aliases."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.sessions
 :reload-modules [:fen.extensions.sessions.commands.session
                  :fen.extensions.sessions]}
