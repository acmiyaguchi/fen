{:name :docs
 :description "In-agent runtime documentation browser"
 :entry-module :fen.extensions.docs
 :reload-modules [:fen.extensions.docs
                  :fen.extensions.docs.contracts]
 :reload-exclude [:fen.extensions.docs.state]}
