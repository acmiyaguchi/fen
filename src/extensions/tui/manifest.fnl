{:name :tui
 :description "First-party termbox2 presenter"
 :enabled-by-default true
 ;; The loader owns first-party extension reload. Behavior modules are cleared
 ;; from package.loaded and re-required; persistent termbox/process state stays
 ;; loaded so /reload does not wedge the terminal or lose transcript/UI state.
 :reload-modules [:extensions.tui.markdown
                  :extensions.tui.paint
                  :extensions.tui.input
                  :extensions.tui]
 :reload-exclude [:extensions.tui.state]}
