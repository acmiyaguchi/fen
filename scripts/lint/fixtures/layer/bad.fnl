;; core requires a module owned by an undeclared rock; app requires a module
;; from a bundled-only (rockspec-less) extension.
{:owners {:fen.util.x :fen-util
          :fen.ext :fen-ext
          :fen.extensions.steer "bundled:ext/steer"}
 :deps {:fen [:fen-util] :fen-core [:fen-util] :fen-util []}
 :files [{:path :core.fnl
          :rock :fen-core
          :dependencies [{:kind :require :module :fen.ext :line 3}]}
         {:path :app.fnl
          :rock :fen
          :dependencies [{:kind :require :module :fen.extensions.steer :line 7}]}]}
