{:name :web
 :description "First-party LuaSocket/SSE browser presenter"
 :enabled-by-default true
 :reload-modules [:fen.extensions.web.ingest
                  :fen.extensions.web.layout
                  :fen.extensions.web.page
                  :fen.extensions.web.server
                  :fen.extensions.web]
 :reload-exclude [:fen.extensions.web.state]}
