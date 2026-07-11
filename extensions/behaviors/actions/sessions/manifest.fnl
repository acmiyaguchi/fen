{:name :sessions
 :description "Conversation and session lifecycle commands plus an agent-callable hot-reload tool."
 :entry-module :fen.extensions.sessions
 :reload-modules [:fen.extensions.sessions.commands.session
                  :fen.extensions.sessions]}
