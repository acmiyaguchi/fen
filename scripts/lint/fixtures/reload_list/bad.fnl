;; One unlisted module, one phantom listing, one multi-module manifest without a list.
{:extensions [{:root :a
               :manifest-path :a/manifest.fnl
               :manifest {:reload-modules [:fen.extensions.a
                                           :fen.extensions.a.gone]}
               :modules [{:module :fen.extensions.a :path :a/init.fnl}
                         {:module :fen.extensions.a.util :path :a/util.fnl}]}
              {:root :b
               :manifest-path :b/manifest.fnl
               :manifest {}
               :modules [{:module :fen.extensions.b :path :b/init.fnl}
                         {:module :fen.extensions.b.x :path :b/x.fnl}]}]}
