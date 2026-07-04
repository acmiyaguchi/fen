{:name :docs
 :description "In-agent runtime documentation browser"
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.docs
 :reload-modules [:fen.extensions.docs
                  :fen.extensions.docs.contracts]
 :reload-exclude [:fen.extensions.docs.state]}
