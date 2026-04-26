;; Mutable terminal state held outside tui.tui so :reload preserves it.
;; tui.tui mutates these fields; main.fnl never touches them directly.
;;
;; Excluded from RELOADABLE in main.fnl — its identity must persist across
;; reloads, otherwise the eventual `leave-raw!` on shutdown would skip the
;; stty restore (because the new module thinks raw mode was never entered)
;; and leave the terminal wedged.

{:raw-active? false
 :saved-stty nil}
