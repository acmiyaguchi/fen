{:name :web
 :description "First-party LuaSocket/SSE browser presenter"
 :entry-module :fen.extensions.web
 :requires-modules [:socket]
 :interactive-only? true
 :presenter :web
 :reload-modules [:fen.extensions.web.ingest
                  :fen.extensions.web.layout
                  :fen.extensions.web.page
                  :fen.extensions.web.server
                  :fen.extensions.web]
 :reload-exclude [:fen.extensions.web.state]}
