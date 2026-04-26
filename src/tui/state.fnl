;; Mutable terminal state held outside tui.tui so /reload preserves it.
;; tui.tui mutates these fields; main.fnl never touches them directly.
;;
;; Excluded from RELOADABLE in main.fnl — its identity must persist across
;; reloads, otherwise the eventual `shutdown` would skip the termbox2
;; teardown (because the new module thinks init was never called) and leave
;; the terminal wedged.

{;; Termbox2 lifecycle. tb-initialized? gates init/shutdown idempotency.
 ;; tb-init-failed? signals main.fnl to print a clean error and exit.
 :tb-initialized? false
 :tb-init-failed? false
 :tb-cols 0
 :tb-rows 0

 ;; Append-only event log. Each entry is the same shape that flowed into
 ;; M.append-event, with expensive bits pre-stringified at append time
 ;; (json.encode for tool args, truncated text for tool results) so redraw
 ;; never has to redo that work.
 :transcript []

 ;; Lines from the bottom of the transcript to anchor the viewport. 0 means
 ;; "follow tail"; positive means the user scrolled up by N wrapped lines.
 :scroll-offset 0

 ;; Input box. May contain literal "\n" for multi-line. cursor is a byte
 ;; offset into input-buf in [0, #input-buf].
 :input-buf ""
 :input-cursor 0

 ;; In-process history of submitted prompts. history-pos = 0 means "current
 ;; draft" (live edit buffer); >0 indexes back from the end. history-draft
 ;; preserves the live buffer when navigating into the ring.
 :history []
 :history-pos 0
 :history-draft ""

 ;; Two-press confirmation for ctrl-c. Cleared on any other key.
 :pending-quit? false

 ;; Status line content. start-ms is os.time at session start; running-tool
 ;; is the name of the tool currently executing (or nil).
 :status-info {:model nil
               :provider nil
               :total-tokens 0
               :start-ms 0
               :running-tool nil
               :thinking? false}}
