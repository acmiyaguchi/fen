;; Every module listed or excluded; single-module extension needs no list.
{:extensions [{:root :a
               :manifest-path :a/manifest.fnl
               :manifest {:reload-modules [:fen.extensions.a]
                          :reload-exclude [:fen.extensions.a.state]}
               :modules [{:module :fen.extensions.a :path :a/init.fnl}
                         {:module :fen.extensions.a.state :path :a/state.fnl}]}
              {:root :b
               :manifest-path :b/manifest.fnl
               :manifest {}
               :modules [{:module :fen.extensions.b :path :b/init.fnl}]}]}
