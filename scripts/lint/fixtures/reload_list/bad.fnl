;; One unlisted module, one phantom listing, one multi-module manifest without
;; a list, one manifest that does not evaluate.
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
                         {:module :fen.extensions.b.x :path :b/x.fnl}]}
              {:root :c
               :manifest-path :c/manifest.fnl
               :manifest {}
               :manifest-error "unexpected closing delimiter"
               :modules [{:module :fen.extensions.c :path :c/init.fnl}]}]}
