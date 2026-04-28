;; Mutable terminal state held outside `extensions.tui` so /reload
;; preserves it. The reloadable `extensions.tui` (init.fnl) mutates
;; these fields; main.fnl never touches them directly.
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

 ;; Global toggle for /expand: when false, :tool-result events render
 ;; as a one-line summary; when true, the truncated body-pretty is
 ;; shown. Per-event override lives on ev.expanded? if we ever need it.
 :expand-tool-results? false

 ;; Global toggle for /markdown: when true (the default), assistant-text
 ;; events are rendered through the Markdown renderer for headings, code
 ;; blocks, lists, etc. When false, assistant text is displayed as plain
 ;; prefixed lines, same as before.
 :markdown? true

 ;; Global toggle for /thinking or ctrl-t: when false (the default),
 ;; assistant thinking blocks render visibly in dim text. When true, they
 ;; collapse to a single "Thinking..." label, matching pi-mono's hidden
 ;; thinking behavior.
 :hide-thinking-block? false

 ;; Two-press confirmation for ctrl-c. Cleared on any other key.
 :pending-quit? false

 ;; Set when the user has pressed ctrl-c during an active agent turn.
 ;; First press requests cancellation; a second press while still busy
 ;; force-quits the session (mirrors the idle two-press quit). Cleared by
 ;; the run loop once the busy state ends.
 :cancel-pressed? false

 ;; Status line content. start-ms is os.time at session start; running-label
 ;; is the name of the tool currently executing (or nil).
 ;;
 ;; Token accounting (mirrors pi-mono's footer breakdown):
 ;;   cum-input        cumulative input tokens billed across all calls (=
 ;;                    "wallet input" — same context re-sent per turn, so
 ;;                    this inflates fast)
 ;;   cum-output       cumulative output tokens generated (real new content)
 ;;   cum-cache-read   cumulative input that hit the prompt cache
 ;;   cum-cache-write  cumulative input billed as cache write
 ;;   last-input       input tokens of the most recent call. This is the
 ;;                    actual live context size — what the next call will
 ;;                    re-send. The single most useful "how big is this
 ;;                    conversation right now" indicator.
 :status-info {:model nil
               :provider nil
               :cum-input 0
               :cum-output 0
               :cum-cache-read 0
               :cum-cache-write 0
               :last-input 0
               :steering-queued 0
               :follow-up-queued 0
               :start-ms 0
               :running-label nil
               :thinking? false
               ;; Set true while a queued cancel is pending — surfaced in
               ;; the status line as `cancelling…` so the user knows the
               ;; first ctrl-c was received even before the agent actually
               ;; bails.
               :cancelling? false
               ;; Per-turn epoch (os.time when the current agent turn
               ;; started). 0 when idle. Used for the elapsed timer
               ;; in the status line.
               :turn-start 0
               ;; Monotonic spinner frame counter, incremented each
               ;; redraw while busy.
               :spin-frame 0}}
