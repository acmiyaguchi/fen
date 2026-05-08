{:name :extensions_inspector
 :description "Extension inspector: /extensions, /reload-extension, and extension detail panel."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.extensions_inspector
 :reload-modules [:fen.extensions.extensions_inspector.util
                  :fen.extensions.extensions_inspector.commands.extension
                  :fen.extensions.extensions_inspector]}
