{:name :web
 :description "First-party LuaSocket/SSE browser presenter"
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.web
 :interactive-only? true
 :presenter :web
 :reload-modules [:fen.extensions.web.ingest
                  :fen.extensions.web.layout
                  :fen.extensions.web.page
                  :fen.extensions.web.server
                  :fen.extensions.web]
 :reload-exclude [:fen.extensions.web.state]}
