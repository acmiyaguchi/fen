;; Persistent TUI state; excluded from RELOADABLE so termbox2 teardown state survives /reload.

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

;; @doc fen.extensions.tui.state.workspaces
;; kind: data
;; signature: [Workspace]
;; summary: Persistent presenter-tab records, including metadata, input mode, activity, source identity, and per-tab view state.
;; tags: tui state tabs workspaces reload

;; @doc fen.extensions.tui.state.active-workspace-id
;; kind: data
;; signature: string|keyword
;; summary: Id of the workspace whose transcript, editor, selection, and render caches are projected through the legacy flat state fields.
;; tags: tui state tabs workspaces focus

;; @doc fen.extensions.tui.state.closed-subagent-workspaces
;; kind: data
;; signature: table
;; summary: Set of explicitly closed subagent tab ids so retained run events do not recreate hidden tabs.
;; tags: tui state tabs subagent

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

{:tb-initialized? false
 :tb-init-failed? false
 :tb-cols 0
 :tb-rows 0

 :dirty? true
 :force-redraw? false
 ;; Geometry of the most recently painted frame, used for mouse hit-testing.
 :paint-layout nil

 ;; Reloadable workspaces.fnl creates/upgrades records; this identity module holds no tab behavior closures.
 :workspaces []
 :active-workspace-id :main-session
 :closed-subagent-workspaces {}
 :spinner-ticks 0
 :spinner-interval-ticks 8
 :animations? true

 ;; Expensive bits are pre-stringified at append time so redraw never redoes that work.
 :transcript []
 ;; Keyed by "<row-type>:<content-index>".
 :streaming-assistant-rows {}
 :transcript-layout-cache nil
 ;; 0 means "follow tail".
 :scroll-offset 0
 :new-content-below? false
 :last-user-jump-index nil
 ;; input-cursor is a byte offset in [0, #input-buf].
 :input-buf ""
 :input-cursor 0
 :paste-active? false
 :paste-buffer ""
 :paste-counter 0
 :pastes {}

 :selection nil
 :selection-paint nil
 :copy-status nil
 :history []
 :history-pos 0
 :history-draft ""
 :expand-tool-results? false
 :markdown? true
 :hide-thinking-block? false
 :pending-quit? false
 ;; Bare-Esc one-tick flag: input.fnl synthesizes MOD_ALT if a key follows; the run loop fires :dismiss otherwise.
 :alt-pending? false
 :on-tick nil
 :cancel-pressed? false

 ;; Kept here so /reload does not reset stall-warning rate limiting.
 :last-stall-warn-ms 0

 ;; cum-* are cumulative billed tokens; cum-input re-counts the full context each turn ("wallet input").
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
               :cancelling? false
               ;; os.time when the current turn started; 0 when idle.
               :turn-start 0
               :spin-frame 0}}
