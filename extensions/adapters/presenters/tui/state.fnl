;; Mutable terminal state held outside `extensions.tui` so /reload
;; preserves it. The reloadable `extensions.tui` (init.fnl) mutates
;; these fields; main.fnl never touches them directly.
;;
;; Excluded from RELOADABLE in main.fnl — its identity must persist across
;; reloads, otherwise the eventual `shutdown` would skip the termbox2
;; teardown (because the new module thinks init was never called) and leave
;; the terminal wedged.

;; @doc fen.extensions.tui.state.tb-initialized?
;; kind: data
;; signature: boolean
;; summary: Persistent termbox2 lifecycle flag used to keep TUI init and shutdown idempotent across reloads.
;; tags: tui state termbox reload

;; @doc fen.extensions.tui.state.tb-init-failed?
;; kind: data
;; signature: boolean
;; summary: Flag set when termbox2 initialization failed so startup can print a clean error and avoid unsafe teardown.
;; tags: tui state termbox errors

;; @doc fen.extensions.tui.state.tb-cols
;; kind: data
;; signature: number
;; summary: Last known terminal column count used by draw/layout code after termbox resize events.
;; tags: tui state termbox layout

;; @doc fen.extensions.tui.state.tb-rows
;; kind: data
;; signature: number
;; summary: Last known terminal row count used by draw/layout code after termbox resize events.
;; tags: tui state termbox layout

;; @doc fen.extensions.tui.state.dirty?
;; kind: data
;; signature: boolean
;; summary: Redraw scheduling flag set when visible TUI state changed and the next presenter loop should repaint.
;; tags: tui state redraw

;; @doc fen.extensions.tui.state.force-redraw?
;; kind: data
;; signature: boolean
;; summary: Strong redraw flag that clears render caches and blanks the presenter before repainting after resize, reload, or display toggles.
;; tags: tui state redraw cache

;; @doc fen.extensions.tui.state.spinner-ticks
;; kind: data
;; signature: number
;; summary: Event-loop tick counter used to pace busy spinner animation without adding another wall-clock dependency.
;; tags: tui state animation

;; @doc fen.extensions.tui.state.spinner-interval-ticks
;; kind: data
;; signature: number
;; summary: Number of event-loop ticks between spinner frame advances while the agent is busy.
;; tags: tui state animation

;; @doc fen.extensions.tui.state.animations?
;; kind: data
;; signature: boolean
;; summary: Global animation toggle controlling whether busy indicators use animated spinner frames or static fallback glyphs.
;; tags: tui state animation settings

;; @doc fen.extensions.tui.state.transcript
;; kind: data
;; signature: [PresenterEvent]
;; summary: Append-only preprocessed transcript event log used as the source of truth for TUI rendering.
;; tags: tui state transcript

;; @doc fen.extensions.tui.state.streaming-assistant-rows
;; kind: data
;; signature: table
;; summary: Lookup table from streaming row keys to transcript rows so delta ingestion can update active assistant output efficiently.
;; tags: tui state transcript streaming

;; @doc fen.extensions.tui.state.transcript-layout-cache
;; kind: data
;; signature: table|nil
;; summary: Width/display-keyed wrapped transcript layout cache used for fast viewport and max-scroll calculations.
;; tags: tui state transcript layout

;; @doc fen.extensions.tui.state.scroll-offset
;; kind: data
;; signature: number
;; summary: Number of wrapped transcript lines above the tail that anchor the viewport when the user scrolls up.
;; tags: tui state scroll transcript

;; @doc fen.extensions.tui.state.new-content-below?
;; kind: data
;; signature: boolean
;; summary: Set while the transcript is scroll-locked and newly appended content is available below the viewport.
;; tags: tui state scroll transcript follow

;; @doc fen.extensions.tui.state.last-user-jump-index
;; kind: data
;; signature: number|nil
;; summary: Transcript event index targeted by the last user-message jump, used so repeated keypresses walk to previous user messages.
;; tags: tui state scroll transcript navigation

;; @doc fen.extensions.tui.state.input-buf
;; kind: data
;; signature: string
;; summary: Current multi-line input buffer contents, including literal newlines and paste markers before submit expansion.
;; tags: tui state input

;; @doc fen.extensions.tui.state.input-cursor
;; kind: data
;; signature: number
;; summary: Byte offset cursor position inside input-buf for terminal input editing.
;; tags: tui state input

;; @doc fen.extensions.tui.state.paste-active?
;; kind: data
;; signature: boolean
;; summary: Bracketed-paste mode flag indicating incoming bytes should accumulate in paste-buffer instead of editing input directly.
;; tags: tui state paste input

;; @doc fen.extensions.tui.state.paste-buffer
;; kind: data
;; signature: string
;; summary: Accumulator for the current bracketed paste before it is compacted into an input marker.
;; tags: tui state paste input

;; @doc fen.extensions.tui.state.paste-counter
;; kind: data
;; signature: number
;; summary: Monotonic id counter for large pasted payload markers stored in the pastes table.
;; tags: tui state paste input

;; @doc fen.extensions.tui.state.pastes
;; kind: data
;; signature: table
;; summary: Table of compact paste marker ids to full pasted text, expanded back into input on submit.
;; tags: tui state paste input

;; @doc fen.extensions.tui.state.history
;; kind: data
;; signature: [string]
;; summary: In-process prompt history ring containing submitted prompts for up/down navigation.
;; tags: tui state history input

;; @doc fen.extensions.tui.state.history-pos
;; kind: data
;; signature: number
;; summary: Prompt history navigation position where zero means the current live draft and positive values index backward from the end.
;; tags: tui state history input

;; @doc fen.extensions.tui.state.history-draft
;; kind: data
;; signature: string
;; summary: Saved live input draft restored when the user navigates back out of history.
;; tags: tui state history input

;; @doc fen.extensions.tui.state.selection
;; kind: data
;; signature: table|nil
;; summary: Active transcript mouse selection ({anchor cursor dragging?}) in screen-cell coordinates, or nil when nothing is selected.
;; tags: tui state selection mouse copy

;; @doc fen.extensions.tui.state.selection-paint
;; kind: data
;; signature: table|nil
;; summary: Per-frame snapshot of plain transcript text keyed by screen row, filled during paint so selection copy can extract the visible selected text.
;; tags: tui state selection paint copy

;; @doc fen.extensions.tui.state.copy-status
;; kind: data
;; signature: table|nil
;; summary: Transient copy-feedback record ({ok? bytes reason at-seconds}) surfaced in the status line after a selection copy attempt.
;; tags: tui state selection copy status

;; @doc fen.extensions.tui.state.expand-tool-results?
;; kind: data
;; signature: boolean
;; summary: Global /expand toggle controlling whether tool-result transcript events show full truncated bodies or one-line summaries.
;; tags: tui state transcript tools

;; @doc fen.extensions.tui.state.markdown?
;; kind: data
;; signature: boolean
;; summary: Global /markdown toggle controlling whether assistant text renders through the terminal markdown renderer or as plain text.
;; tags: tui state markdown settings

;; @doc fen.extensions.tui.state.hide-thinking-block?
;; kind: data
;; signature: boolean
;; summary: Global /thinking toggle controlling whether assistant reasoning blocks render visibly or collapse to a compact Thinking label.
;; tags: tui state thinking settings

;; @doc fen.extensions.tui.state.pending-quit?
;; kind: data
;; signature: boolean
;; summary: Two-press ctrl-c confirmation flag for idle quit behavior, cleared by any non-quit key.
;; tags: tui state input quit

;; @doc fen.extensions.tui.state.alt-pending?
;; kind: data
;; signature: boolean
;; summary: One-tick bare-Esc state used to distinguish dismiss from Alt-key combinations in INPUT_ESC mode.
;; tags: tui state input keyboard

;; @doc fen.extensions.tui.state.on-tick
;; kind: data
;; signature: function|nil
;; summary: Cooperative tick callback published by the run loop so nested selectors can keep agent coroutines and HTTP drains moving.
;; tags: tui state cooperative input

;; @doc fen.extensions.tui.state.cancel-pressed?
;; kind: data
;; signature: boolean
;; summary: Busy-turn ctrl-c flag recording that cancellation was requested before the agent loop observes and clears it.
;; tags: tui state cancel input

;; @doc fen.extensions.tui.state.status-info
;; kind: data
;; signature: table
;; summary: Persistent status-line model, token, queue, retry, thinking, cancellation, elapsed-time, and spinner metadata.
;; tags: tui state status

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
 :spinner-interval-ticks 8
 :animations? true

 ;; Append-only event log. Each entry is the same shape that flowed into
 ;; M.append-event, with expensive bits pre-stringified at append time
 ;; (json.encode for tool args, truncated text for tool results) so redraw
 ;; never has to redo that work.
 :transcript []

 ;; Active streaming assistant rows keyed by "<row-type>:<content-index>".
 ;; Lets delta ingestion append to the current row without repeatedly scanning
 ;; the transcript tail.
 :streaming-assistant-rows {}

 ;; Transcript-wide rendered row index keyed by width/display toggles. Built
 ;; lazily by panels/transcript.fnl for O(1) max-scroll and near-visible-row
 ;; viewport lookup in long sessions.
 :transcript-layout-cache nil

 ;; Lines from the bottom of the transcript to anchor the viewport. 0 means
 ;; "follow tail"; positive means the user scrolled up by N wrapped lines.
 :scroll-offset 0

 ;; True after content arrives while scroll-offset is positive. Cleared when
 ;; the user returns to the live bottom.
 :new-content-below? false

 ;; Last transcript event index selected by the jump-to-user keybinding.
 ;; nil means the next jump starts from the current viewport anchor; a value
 ;; means repeated presses continue with earlier user-authored messages.
 :last-user-jump-index nil

 ;; Input box. May contain literal "\n" for multi-line. cursor is a byte
 ;; offset into input-buf in [0, #input-buf].
 :input-buf ""
 :input-cursor 0

 ;; Bracketed paste state. Large pastes are stored here and represented in
 ;; input-buf by compact markers; submit expands markers back to full text.
 :paste-active? false
 :paste-buffer ""
 :paste-counter 0
 :pastes {}

 ;; Native transcript selection. selection is nil when nothing is selected,
 ;; else {:anchor {:x :y} :cursor {:x :y} :dragging?} in screen cells.
 ;; selection-paint is a per-frame snapshot {:rows {screen-y -> plain-text}}
 ;; filled during paint so a mouse-release copy can extract selected text.
 ;; copy-status is a transient {:ok? :bytes :reason :at-seconds} feedback record.
 :selection nil
 :selection-paint nil
 :copy-status nil

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

 ;; Monotonic timestamp of the last logged TUI stall warning.
 ;; Kept here so /reload does not reset rate limiting.
 :last-stall-warn-ms 0

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
               :thinking-status nil
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
