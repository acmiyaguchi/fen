{:name :tui
 :description "First-party termbox2 presenter"
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.tui
 :interactive-only? true
 :presenter :tui
 ;; The loader owns first-party extension reload. Behavior modules are cleared
 ;; from package.loaded and re-required; persistent termbox/process state stays
 ;; loaded so /reload does not wedge the terminal or lose transcript/UI state.
 :reload-modules [:fen.extensions.tui.markdown
                  :fen.extensions.tui.draw
                  :fen.extensions.tui.panels.transcript
                  :fen.extensions.tui.panels.busy
                  :fen.extensions.tui.panels.status
                  :fen.extensions.tui.panels.errors
                  :fen.extensions.tui.paint
                  :fen.extensions.tui.input
                  :fen.extensions.tui.select
                  :fen.extensions.tui.ingest
                  :fen.extensions.tui]
 :reload-exclude [:fen.extensions.tui.state]}
