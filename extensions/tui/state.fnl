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

 ;; Dirty-driven redraw scheduling. dirty? means visible state changed and
 ;; the next presenter-loop iteration should repaint. force-redraw? means
 ;; clear render caches and blank-present before the repaint (resize,
 ;; reload, display-mode toggles). Spinner cadence is capped by event-loop
 ;; ticks, avoiding an extra wall-clock dependency while still decoupling
 ;; busy animation from idle redraws.
 :dirty? true
 :force-redraw? false
 :spinner-ticks 0
 :spinner-interval-ticks 5

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

 ;; Set when KEY_ESC has fired and the run loop hasn't seen a follow-up
 ;; key yet. INPUT_ESC mode emits bare Esc as KEY_ESC immediately, but
 ;; we want Alt-key shortcuts (Esc + key within one tick) to still
 ;; surface as MOD_ALT — so input.fnl synthesizes MOD_ALT on the next
 ;; key when this flag is set, and the run loop fires `:dismiss` if a
 ;; tick passes without a follow-up.
 :alt-pending? false

 ;; Cooperative tick callback published by M.run. The select.fnl
 ;; overlay reads this and calls it from its inner peek_event loop so
 ;; agent coroutines and HTTP drains keep advancing while the user
 ;; picks. nil when no run loop is active.
 :on-tick nil

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
 ;;   last-input       provider-reported input tokens of the most recent call.
 ;;   approx-context   local tokenizer-independent estimate of the current
 ;;                    system prompt + message history shown in the status bar.
 :status-info {:model nil
               :provider nil
               :cum-input 0
               :cum-output 0
               :cum-cache-read 0
               :cum-cache-write 0
               :last-input 0
               :approx-context 0
               :steering-queued 0
               :follow-up-queued 0
               :start-ms 0
               :running-label nil
               :retrying? false
               :retry-attempt 0
               :retry-max-attempts 0
               :retry-delay-ms 0
               :retry-reason nil
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
