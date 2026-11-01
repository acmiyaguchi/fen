;; core requires a module owned by an undeclared rock.
{:owners {:fen.util.x :fen-util :fen.ext :fen-ext}
 :deps {:fen-core [:fen-util] :fen-util []}
 :files [{:path :core.fnl
          :rock :fen-core
          :dependencies [{:kind :require :module :fen.ext :line 3}]}]}
