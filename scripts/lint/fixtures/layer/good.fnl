;; Direct and transitive declared deps, own-rock, optional, and external
;; requires; a bundled-only extension may require anything; a source-only
;; (unpublished) module of a real rock is not checked.
{:owners {:fen.util.x :fen-util
          :fen.core.y :fen-core
          :fen.app :fen
          :fen.ext :fen-ext
          :fen.extensions.steer "bundled:ext/steer"}
 :deps {:fen [:fen-core] :fen-core [:fen-util] :fen-util []}
 :files [{:path :app.fnl
          :rock :fen
          :dependencies [{:kind :require :module :fen.util.x :line 1}
                         {:kind :late-require :module :fen.core.y :line 2}
                         {:kind :require :module :fen.app :line 3}
                         {:kind :optional-require :module :fen.ext :line 4}
                         {:kind :require :module :cjson :line 5}]}
         {:path :ext/presenter.fnl
          :rock "bundled:ext/presenter"
          :dependencies [{:kind :require :module :fen.app :line 1}
                         {:kind :require :module :fen.extensions.steer :line 2}]}
         {:path :testing/tui.fnl
          :rock :fen-testing
          :source-only? true
          :dependencies [{:kind :require :module :fen.ext :line 1}]}]}
