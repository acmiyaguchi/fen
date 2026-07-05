;; TUI presenter extension: the litmus test for the issue #15 api.
;;
;; Layout (top to bottom):
;;   row 0      status line: provider:model | ctx:N | busy:tool | scrolled:N
;;   row 1..    transcript region (scrollable; auto-tails unless scrolled up)
;;   row H-K..  multi-line input box (K rows; grows with newlines, capped)
;;
;; Rendering lives in `extensions.tui.paint`, input handling in
;; `extensions.tui.input`, and bus->transcript ingestion in
;; `extensions.tui.ingest`. This file owns two things:
;;
;;   1. Lifecycle: init!, shutdown, run, reset-conversation!,
;;      set-status-info — main.fnl drives these for bootstrap/teardown.
;;   2. The extension-registration block (presenter, command, and event
;;      subscriptions). Other TUI modules may use `core.extensions` for
;;      bus events or registered UI contributions, but lifecycle ownership
;;      stays here.
;;
;; Hot-reload note: every helper is a field on the module table `M` and
;; internal calls dispatch through `M.<name>` so a /reload that mutates
;; this module table picks up new code on the next call. Mutable state
;; lives in `extensions.tui.state` (NOT reloaded) — termbox2 binds
;; process-global C state, so its initialized? flag must persist across
;; reloads, otherwise shutdown would skip teardown and leave the terminal
;; wedged. Bus subscriptions and registrations live in
;; `core.extensions.state` (also NOT reloaded), so re-running this body
;; via /reload calls unregister-by-owner :tui first to avoid doubling.
;;
;; Termbox2 itself maintains a back/front buffer with internal diffing,
;; so we don't carry our own diff layer: every redraw clears, repaints,
;; and presents. Cheap enough to call on every keystroke and event.

(local state (require :fen.extensions.tui.state))
(local tb (require :termbox2))
(local paint (require :fen.extensions.tui.paint))
(local input (require :fen.extensions.tui.input))
(local transcript (require :fen.extensions.tui.panels.transcript))
(local busy-panel (require :fen.extensions.tui.panels.busy))
(local errors-panel (require :fen.extensions.tui.panels.errors))
(local select-mod (require :fen.extensions.tui.select))
(local completion (require :fen.extensions.tui.completion))
(local ingest (require :fen.extensions.tui.ingest))
(local log (require :fen.util.log))
(local log-sink (require :fen.util.log_sink))
(local path (require :fen.util.path))
(local process (require :fen.util.process))

(fn version-info []
  (let [(ok? v) (pcall require :fen.version)]
    (when ok?
      (if (and (= (type v) :table) (= (type v.info) :function))
          (let [(info-ok? info) (pcall v.info)]
            (when info-ok? info))
          (= (type v) :table)
          v
          {:version (tostring v)}))))

(fn version-status-text []
  "Return a compact build/source identity for the status bar."
  (let [info (version-info)]
    (when info
      (let [raw (tostring (or info.version info.gitShortRev "unknown"))
            dirty? (or info.dirty (not= nil (string.find raw "%-dirty$")))
            short (or (string.match raw "^(.-)%-dirty$") raw)
            prefix (if (= info.source "source") "src:" "fen:")]
        (.. prefix short (if dirty? "*" ""))))))

(local STATUS-VERSION (version-status-text))

(local M {})

(fn log-file-path []
  "Default log file path while the TUI owns the terminal. Stays under the
   same XDG_STATE_HOME/fen directory used for errors.jsonl and session
   storage so users find logs where they already look for state."
  (or (os.getenv :FEN_LOG_FILE)
      (.. (path.state-dir :fen) "/fen.log")))

(fn open-log-sink! []
  "Idempotent — returns immediately when a sink is already active so
   repeated M.init! calls (hot reload, hard refresh, suspend resume)
   don't pointlessly churn the file handle. Reopens after a write-line
   failure cleared the sink. Failures here are non-fatal: log output
   simply keeps going to stderr (and corrupting the screen, which is the
   bug we're working around) rather than crashing startup."
  (when (not (log-sink.active?))
    (let [p (log-file-path)]
      (path.ensure-dir! (path.dirname p))
      (log-sink.open! p))))

;; ---------- lifecycle ----------

;; @doc fen.extensions.tui.init!
;; kind: function
;; signature: (init!) -> nil
;; summary: Initialize or refresh termbox runtime state, terminal modes, dimensions, and bracketed paste support.
;; tags: tui lifecycle termbox reload
(fn M.init! []
  "Initialize termbox2 (gated by tb-initialized? — runs at most once per
   process) and apply runtime config (idempotent — runs on every call so
   /reload can pick up new input/output mode flags or other runtime
   settings without a process restart). The /reload built-in command
   invokes this after re-requiring extensions.tui."
  (paint.ensure-state-defaults!)
  (when (not state.tb-initialized?)
    (let [(rc _err _code) (tb.init)]
      (if (and rc (>= rc 0))
          (do (set state.tb-initialized? true)
              (set state.tb-init-failed? false)
              (when (= state.status-info.start-ms 0)
                (set state.status-info.start-ms (os.time))))
          (set state.tb-init-failed? true))))
  (when state.tb-initialized?
    ;; Reroute log.* to a file before any other code can call log.warn —
    ;; once termbox owns the terminal, stderr writes corrupt the live
    ;; frame. Lives in the re-assert block so /reload and recovery after
    ;; a write-line failure both pick the sink back up.
    (open-log-sink!)
    ;; Re-cache dims (resize may have changed them) and re-assert input/output
    ;; modes. tb.set_input_mode immediately emits the SGR-mouse enable/disable
    ;; escape sequences, so changing flags here actually flips the terminal's
    ;; reporting mode mid-session. Caveat: new symbols added to the C shim
    ;; (e.g. extra TB_KEY_* constants) still require a process restart, since
    ;; package.loaded["termbox2"] is cached for the process lifetime.
    (set state.tb-cols (tb.width))
    (set state.tb-rows (tb.height))
    ;; INPUT_ESC surfaces bare Esc as KEY_ESC immediately. INPUT_ALT
    ;; would buffer bare Esc waiting for a follow-up — that's why
    ;; pressing Esc by itself in INPUT_ALT mode looks silent and the
    ;; *next* keystroke gets MOD_ALT (an easy way to accidentally
    ;; quit). input.fnl synthesizes MOD_ALT itself when KEY_ESC is
    ;; immediately followed by another key, so Alt-key shortcuts still
    ;; work.
    ;; INPUT_MOUSE enables SGR mouse reporting (mode 1006), which tmux
    ;; forwards to the foreground pane when `set -g mouse on`.
    (tb.set_input_mode (bor tb.INPUT_ESC tb.INPUT_MOUSE))
    ;; Ask terminals to wrap clipboard pastes in ESC[200~/ESC[201~ so
    ;; pasted newlines don't look like Enter-submit keystrokes.
    (io.write "\27[?2004h")
    (io.flush)
    (tb.set_output_mode tb.OUTPUT_NORMAL)))

;; @doc fen.extensions.tui.shutdown
;; kind: function
;; signature: (shutdown) -> nil
;; summary: Tear down termbox and bracketed paste mode when the TUI presenter exits.
;; tags: tui lifecycle termbox
(fn M.shutdown []
  (when state.tb-initialized?
    ;; Leave the user's terminal without bracketed paste mode after fen exits.
    (io.write "\27[?2004l")
    (io.flush)
    (tb.shutdown)
    (set state.tb-initialized? false)
    ;; Stderr is the terminal again — release the sink so trailing log
    ;; lines (shutdown errors, etc.) land in front of the user.
    (log-sink.close!))
  (set state.presenter-ctx nil))

;; @doc fen.extensions.tui.hard-refresh!
;; kind: function
;; signature: (hard-refresh!) -> nil
;; summary: Recover from external terminal corruption by re-asserting terminal modes and forcing a full repaint.
;; tags: tui lifecycle redraw termbox
(fn M.hard-refresh! []
  "Recover the screen after external terminal interference (another process
   writing to the tty, tmux/resize glitches, front-buffer desync). M.init!'s
   idempotent path re-asserts input/output modes and bracketed paste; force-redraw!
   then blank-presents to invalidate termbox's front buffer and repaints. Scroll
   position and input buffer live in persistent state, so both are preserved."
  (M.init!)
  (paint.force-redraw!))

;; @doc fen.extensions.tui.suspend!
;; kind: function
;; signature: (suspend!) -> nil
;; summary: Ctrl-Z job-control suspend: restore the terminal, stop with SIGTSTP, then re-init and repaint on resume.
;; tags: tui lifecycle suspend termbox signal
(fn M.suspend! []
  "Suspend fen to the shell like any full-screen app. Raw mode disables ISIG,
   so Ctrl-Z reaches us as a key rather than SIGTSTP; we restore the terminal
   (leave termbox/raw mode, disable bracketed paste) before stopping so the
   recovered shell is usable. tb.raise_sigtstp stops the foreground process
   group (matching tty Ctrl-Z, including wrappers like make dev) until
   `fg`/SIGCONT, then we re-init termbox and force a full repaint."
  (M.shutdown)
  (tb.raise_sigtstp)
  (M.init!)
  (paint.force-redraw!))

;; @doc fen.extensions.tui.reset-conversation!
;; kind: function
;; signature: (reset-conversation!) -> nil
;; summary: Clear transcript, streaming, input, paste, scroll, and per-turn status state while preserving UI identity.
;; tags: tui lifecycle session reset
(fn M.reset-conversation! []
  "Clear per-conversation TUI state for /new while preserving process/UI
   settings that should survive a fresh session (provider/model, dimensions,
   input history, termbox lifecycle)."
  (paint.ensure-state-defaults!)
  (let [s state.status-info
        provider s.provider
        model s.model
        thinking-status s.thinking-status]
    (set state.transcript [])
    (set state.streaming-assistant-rows {})
    (set state.transcript-layout-cache nil)
    (set state.scroll-offset 0)
    (set state.last-user-jump-index nil)
    (set state.input-buf "")
    (set state.input-cursor 0)
    (set state.paste-active? false)
    (set state.paste-buffer "")
    (set state.paste-counter 0)
    (set state.pastes {})
    (set state.history-pos 0)
    (set state.history-draft "")
    (set state.pending-quit? false)
    (completion.close!)
    (set s.provider provider)
    (set s.model model)
    (set s.thinking-status thinking-status)
    (set s.cum-input 0)
    (set s.cum-output 0)
    (set s.cum-cache-read 0)
    (set s.cum-cache-write 0)
    (set s.last-input 0)
    (set s.start-ms (os.time))
    (set s.running-label nil)
    (set s.retrying? false)
    (set s.retry-attempt 0)
    (set s.retry-max-attempts 0)
    (set s.retry-delay-ms 0)
    (set s.retry-reason nil)
    (set s.thinking? false)
    (set s.turn-start 0)
    (set s.spin-frame 0))
  (paint.invalidate-full!))

;; @doc fen.extensions.tui.set-status-info
;; kind: function
;; signature: (set-status-info info) -> nil
;; summary: Merge provider, model, queue, and context details into the persistent TUI status line state.
;; tags: tui status presenter
(fn M.set-status-info [info]
  "Optional: caller (main.fnl) can populate provider/model on the status
   line. Falls back to nil → '?' rendering otherwise."
  (paint.ensure-state-defaults!)
  (when info.provider (set state.status-info.provider info.provider))
  (when info.model (set state.status-info.model info.model))
  (when (not= info.thinking-status nil)
    (set state.status-info.thinking-status
         (if (= info.thinking-status false) nil info.thinking-status)))
  (when info.steering-queued (set state.status-info.steering-queued info.steering-queued))
  (when info.follow-up-queued (set state.status-info.follow-up-queued info.follow-up-queued))
  (when info.approx-context (set state.status-info.approx-context info.approx-context))
  (paint.invalidate!))

(local ACTIVE-TICK-MS 30)
(local IDLE-TICK-MS 300)
(local DEFAULT-STALL-WARN-MS 250)
(local STALL-WARN-COOLDOWN-MS 5000)

(fn stall-warn-ms []
  (let [raw (os.getenv :FEN_TUI_STALL_WARN_MS)
        n (and raw (tonumber raw))]
    (if (and n (> n 0)) n DEFAULT-STALL-WARN-MS)))

(fn fmt-field [s]
  "Quote nil/empty as '-' so key=val lines stay grep-friendly even when a
   status slot is unset (typical at idle, between turns, or before the
   first agent call)."
  (let [v (tostring (if (or (= s nil) (= s "")) "-" s))]
    (string.gsub v "%s+" "_")))

(fn coroutine-stack [?get-turn]
  "Best-effort traceback of the agent coroutine the way it's parked right
   now. `warn-if-stalled!` fires AFTER the resume that took N ms returned,
   so the coroutine has just yielded — its current parked frame is the
   yield boundary on the *trailing* edge of the slow section. Combined
   with the previous entry's traceback, two consecutive stall records
   bracket the slow code between yield points. Returns nil when no
   coroutine is in flight (turn already finished, or no get-turn thunk
   was wired in). Wraps every step in pcall because we run outside the
   on-tick xpcall — a thrown error here would take the presenter down."
  (when ?get-turn
    (let [(ok? co) (pcall ?get-turn)]
      (when (and ok? (= (type co) :thread))
        (let [(stat-ok? status) (pcall coroutine.status co)]
          (when (and stat-ok? (not= status :dead))
            (let [(tb-ok? tb) (pcall debug.traceback co)]
              (when tb-ok? tb))))))))

(fn M.input-meta [?ev]
  "Diagnostics for an input-phase stall: which event was being handled and how
   much buffered text it touched. Input stalls (e.g. a large bracketed paste)
   carry no coroutine stack, so this is the only signal into what was slow."
  (let [ev (or ?ev {})]
    (string.format
      "event=%s key=%s ch=%s mod=%s paste=%s paste_bytes=%d buf_bytes=%d"
      (fmt-field ev.type)
      (fmt-field ev.key)
      (fmt-field ev.ch)
      (fmt-field ev.mod)
      (fmt-field state.paste-active?)
      (length (or state.paste-buffer ""))
      (length (or state.input-buf "")))))

(fn M.warn-if-stalled! [phase start-ms ?get-turn ?ev]
  (let [threshold (stall-warn-ms)
        now (process.monotonic-ms)
        elapsed (- now start-ms)]
    (when (and (> elapsed threshold)
               (>= (- now (or state.last-stall-warn-ms 0))
                   STALL-WARN-COOLDOWN-MS))
      (set state.last-stall-warn-ms now)
      (let [s state.status-info
            line (string.format
                   "tui-stall phase=%s elapsed_ms=%d tool=%s provider=%s model=%s retry=%s retry_attempt=%s thinking=%s"
                   (tostring phase)
                   elapsed
                   (fmt-field s.running-label)
                   (fmt-field s.provider)
                   (fmt-field s.model)
                   (fmt-field s.retrying?)
                   (fmt-field s.retry-attempt)
                   (fmt-field s.thinking?))
            line (if (= phase :input)
                     (.. line " " (M.input-meta ?ev))
                     line)
            tb (coroutine-stack ?get-turn)]
        (log.warn (if tb
                      (.. line "\ncoroutine-stack:\n" tb)
                      line))))))

;; @doc fen.extensions.tui.peek-timeout-ms
;; kind: function
;; signature: (peek-timeout-ms is-busy?) -> number
;; summary: Choose a short or idle termbox poll timeout based on dirty state, Alt resolution, busy work, and animation needs.
;; tags: tui loop polling performance
(fn M.peek-timeout-ms [is-busy?]
  "Use a short poll while busy or resolving Esc/Alt, but sleep longer when the
   TUI is clean and idle. Dirty redraw already prevents repaint churn; this
   prevents a 33Hz no-op wakeup loop on slow/battery-constrained terminals."
  (if (or state.dirty?
          state.force-redraw?
          state.alt-pending?
          (and is-busy? (is-busy?))
          (paint.busy?))
      ACTIVE-TICK-MS
      IDLE-TICK-MS))

;; @doc fen.extensions.tui.interrupted-syscall?
;; kind: function
;; signature: (interrupted-syscall? err) -> boolean
;; summary: True when a peek_event error string is a transient signal-interrupted syscall (EINTR), which must not be treated as session-fatal.
;; tags: tui loop termbox signal eintr
(fn M.interrupted-syscall? [err]
  "A signal (resize/job-control/SIGCHLD) can interrupt termbox's
   select()/read(); the native shim retries these, but a stale
   cross-built termbox2.so may surface it as `tb_*_event failed:
   Interrupted ... call`. EINTR is transient — the loop treats it as an
   idle tick, never a session-fatal error (#132)."
  (if (and err
           (string.find (string.lower (tostring err)) "interrupted" 1 true))
      true
      false))

(local first-line (. (require :fen.util.text) :first-line))

(fn table-count [t]
  (var n 0)
  (each [_ _ (pairs (or t {}))]
    (set n (+ n 1)))
  n)

;; @doc fen.extensions.tui.run
;; kind: function
;; signature: (run on-submit on-tick on-cancel is-busy? ?get-turn) -> nil
;; summary: Run the TUI presenter loop, repainting, polling termbox events, ticking cooperative work, and dispatching input. ?get-turn optionally returns the in-flight agent coroutine for richer stall diagnostics.
;; tags: tui presenter loop termbox
(fn M.run [on-submit on-tick on-cancel is-busy? ?get-turn]
  (when state.tb-init-failed?
    (io.stderr:write
      "fen: termbox2 init failed (TUI requires an interactive terminal)\n")
    (os.exit 1))
  ;; Publish on-tick so cooperative inner loops (e.g. select.fnl's
  ;; overlay) can keep ticks firing while they own the foreground.
  (set state.on-tick on-tick)
  (ingest.append-event
    {:type :info
     :text "fen — ctrl-d to quit, ctrl-c twice to quit, ctrl-j for newline"})
  (var quit? false)
  (while (not quit?)
    (paint.advance-spinner-if-due!)
    (paint.redraw-if-needed!)
    (let [(ev err code) (tb.peek_event (M.peek-timeout-ms is-busy?))]
      (if (and (= ev nil)
               (or (= code tb.ERR_NO_EVENT)
                   ;; A signal interrupted termbox's select()/read() and
                   ;; the native shim didn't retry it (stale cross-built
                   ;; binary). EINTR is transient — fall through to the
                   ;; idle tick instead of killing the session (#132).
                   (M.interrupted-syscall? err)))
          ;; Idle tick. If a bare KEY_ESC fired on a recent event and no
          ;; follow-up arrived within the tick, fire :dismiss so panels
          ;; close. See state.alt-pending? for the rationale.
          (when state.alt-pending?
            (set state.alt-pending? false)
            (state.api.emit {:type :dismiss}))
          (= ev nil)
          (do (state.api.emit
                {:type :error
                 :error (.. "tb_peek_event failed: " (tostring err))})
              (set quit? true))
          (let [start-ms (process.monotonic-ms)
                (ok? r) (xpcall #(input.handle-event ev on-submit on-cancel is-busy?)
                                 debug.traceback)]
            (M.warn-if-stalled! :input start-ms ?get-turn ev)
            (if (not ok?)
                (state.api.emit {:type :error
                                  :error (.. "tui: " (first-line r))
                                  :traceback (tostring r)})
                r
                (set quit? true))))
      (when (and (not quit?) on-tick)
        (let [start-ms (process.monotonic-ms)
              (ok? err) (xpcall on-tick debug.traceback)]
          (M.warn-if-stalled! :tick start-ms ?get-turn)
          (when (not ok?)
            (state.api.emit {:type :error
                              :error (.. "on-tick: " (first-line err))
                              :traceback (tostring err)})))))
    ;; Once the agent turn finishes (the coroutine no longer reports busy)
    ;; clear any first-press cancel state so the next ctrl-c arms a quit
    ;; rather than landing on a stale "cancel pressed" branch that could
    ;; force-quit on the next one. Status indicator is cleared by
    ;; append-event when :cancelled fires; this mop-up handles the case
    ;; where the turn completed normally between presses.
    (when (and state.cancel-pressed? is-busy? (not (is-busy?)))
      (set state.cancel-pressed? false)
      (set state.status-info.cancelling? false)
      (paint.invalidate!))))

;; -----------------------------------------------------------------
;; Extension registration (issue #15, Step 3b/3c)
;; -----------------------------------------------------------------
;;
;; The TUI registers as a presenter and owns its TUI-coupled slash
;; commands (/expand, /markdown, /thinking-blocks). Other commands like /new
;; and /reload reach the TUI through bus events instead of direct calls,
;; keeping the contract one-way: outside code emits, the TUI subscribes.
;;
;; Reload-safe: the loader drops the prior owner-tagged batch before
;; re-requiring this module, so subscriptions and registrations do not
;; double up across /reload.

(fn M.register [api]
  (set state.api api)

;; The TUI is the active presenter — every event emitted on the bus
;; lands in the transcript via append-event, EXCEPT presenter-control
;; events that have their own dedicated subscribers below (clearing
;; the transcript or redrawing is not transcript content).
(local PRESENTER-CONTROL-EVENTS
  {:agent-turn-complete true
   :message-appended true
   :reset-conversation true
   :reinit-presenter true
   :redraw true
   :hard-refresh true
   :suspend true
   :set-status-info true
   :set-thinking-blocks true})

(api.on :*
        (fn [ev]
          (when (not (. PRESENTER-CONTROL-EVENTS ev.type))
            (ingest.append-event ev))))

;; Bus events that ask the TUI to do something. Built-in commands
;; (/new, /reload) emit these instead of importing the TUI module.
(api.on :reset-conversation
        (fn [_] (M.reset-conversation!)))
(api.on :reinit-presenter
        (fn [_]
          (M.init!)
          (paint.invalidate-full!)))
(api.on :redraw
        (fn [_] (paint.invalidate-full!)))
;; Stronger than :redraw — re-asserts terminal modes and blank-presents to
;; recover from external corruption. Driven by ctrl-l and the /redraw command.
(api.on :hard-refresh
        (fn [_] (M.hard-refresh!)))
;; Ctrl-Z job-control suspend. Synchronous: the emit blocks here (process
;; stopped) until fg/SIGCONT, then suspend! re-inits and repaints before return.
(api.on :suspend
        (fn [_] (M.suspend!)))
(api.on :set-status-info
        (fn [ev] (M.set-status-info (or ev.info {}))))
(api.on :set-thinking-blocks
        (fn [ev]
          (let [visible? (not= ev.visible? false)]
            (set state.hide-thinking-block? (not visible?))
            (paint.invalidate-full!))))
(api.on :dismiss
        (fn [_]
          (when (completion.active?)
            (completion.dismiss!)
            (paint.invalidate!))))

;; First-party status blocks. These use the same :status kind third-party
;; extensions will use; paint.fnl composes them at draw time.
(api.register :status
              {:name :model
               :side :left
               :order 10
               :render (fn [_ctx]
                         (let [s state.status-info]
                           {:text (.. (or s.provider "?") ":" (tostring (or s.model "?")))
                            :style :status}))})

(api.register :status
              {:name :thinking
               :side :left
               :order 15
               :render (fn [_ctx]
                         (when state.status-info.thinking-status
                           {:text (tostring state.status-info.thinking-status)
                            :style :status}))})

(api.register :status
              {:name :context
               :side :left
               :order 20
               :render (fn [_ctx]
                         {:text (.. "ctx:~" (paint.fmt-tokens (or state.status-info.approx-context
                                                                 state.status-info.last-input)))
                          :style :status})})

(api.register :status
              {:name :steering-queue
               :side :left
               :order 30
               :render (fn [_ctx]
                         (let [n (or state.status-info.steering-queued 0)]
                           (when (> n 0)
                             {:text (.. "steer:" (tostring n))
                              :style :status})))})

(api.register :status
              {:name :follow-up-queue
               :side :left
               :order 40
               :render (fn [_ctx]
                         (let [n (or state.status-info.follow-up-queued 0)]
                           (when (> n 0)
                             {:text (.. "follow:" (tostring n))
                              :style :status})))})

(api.register :status
              {:name :attention
               :side :left
               :order 50
               :render (fn [_ctx]
                         (let [text (if state.pending-quit? "ctrl-c again to quit"
                                        state.status-info.cancelling? "cancelling…"
                                        "")]
                           (when (not= text "")
                             {:text text :style :status})))})

(api.register :status
              {:name :scroll
               :side :left
               :order 60
               :render (fn [_ctx]
                         (when (> state.scroll-offset 0)
                           {:text (.. "scrolled:" (tostring state.scroll-offset)
                                      (if state.new-content-below? " ↓new" ""))
                            :style :status}))})

(api.register :status
              {:name :version
               :side :right
               :order 100
               :render (fn [_ctx]
                         (when (and STATUS-VERSION (not= STATUS-VERSION ""))
                           {:text STATUS-VERSION
                            :style :status}))})

;; First-party panels. Busy row is the only one in v1; lives above input
;; with order 10 (closest to the input box). Collapses to height 0 when
;; idle so the row goes back to the transcript.
;; @doc register-site:panel:errors
;; summary: TUI error introspection panel showing recent error summaries and traceback details.
;; tags: panel tui errors
(api.register :panel (errors-panel.spec))
;; @doc register-site:panel:busy
;; summary: TUI busy-state panel showing spinner, retry information, and current turn elapsed time.
;; tags: panel tui status
(api.register :panel (busy-panel.spec))
;; @doc register-site:panel:completion
;; summary: TUI inline slash-command/argument completion menu, filter-as-you-type above the input line.
;; tags: panel tui completion
(api.register :panel (completion.panel-spec))

;; Presenter slot: marks the TUI as the active presenter, supplies the
;; generic lifecycle methods `core.extensions` dispatches, and exposes a
;; ui table the api.ui slot delegates to. notify lands as a dim :info
;; line in the transcript; prompt/select are presenter-specific and not
;; yet wired (the TUI input is always a multi-line full-screen field,
;; not an inline modal).
(api.register :presenter
              {:name :tui
               :active? true
               :init (fn [_ctx] (M.init!))
               :shutdown (fn [_ctx] (M.shutdown))
               :run (fn [ctx]
                      ;; Keep the full presenter/run context available to
                      ;; input-time completers (for opts.extra-skill-paths,
                      ;; cooperative yields, and future command-specific
                      ;; completion needs) without changing input's event
                      ;; dispatch signature.
                      (set state.presenter-ctx ctx)
                      (M.run ctx.on-submit ctx.on-tick
                             ctx.request-cancel ctx.is-busy?
                             ctx.get-turn))
               :ui {:notify (fn [text _opts]
                              (ingest.append-event
                                {:type :info :text (tostring text)}))
                    :prompt (fn [_opts] nil)
                    :select (fn [opts] (select-mod.tui-select opts))}})

;; TUI-coupled slash commands. These mutate `state` (extensions.tui.state)
;; directly because they live inside the TUI extension; that's the
;; whole point of moving them here in Step 3c.

(fn first-arg [args]
  (string.match (or args "") "^(%S+)"))

(api.register :control
              {:name :jump-to-user-message
               :keys ["ctrl-g"]
               :order 5
               :description "Jump to the latest user message; repeat for previous messages"})

(api.register :control
              {:name :jump-to-live-bottom
               :keys ["ctrl-y"]
               :order 6
               :description "Jump to the live bottom and resume following transcript output"})

(api.register :control
              {:name :toggle-tool-results
               :keys ["ctrl-o"]
               :order 10
               :description "Toggle tool-result bodies"})

(api.register :control
              {:name :toggle-thinking-blocks
               :keys ["ctrl-t"]
               :order 20
               :description "Toggle thinking blocks"})

(api.register :control
              {:name :quit
               :keys ["ctrl-c" "ctrl-d"]
               :order 30
               :description "Quit; ctrl-c also clears input or cancels a busy turn"})

(api.register :control
              {:name :hard-refresh
               :keys ["ctrl-l"]
               :order 40
               :description "Redraw the screen / recover from terminal corruption"})

(api.register :control
              {:name :suspend
               :keys ["ctrl-z"]
               :order 50
               :description "Suspend to the shell (resume with fg)"})

(api.register :command
              {:name :expand
               :order 10
               :description "Toggle full vs collapsed tool-result bodies"
               :handler (fn [args _state]
                          (let [arg (first-arg args)
                                new-val (if (= arg :on) true
                                            (= arg :off) false
                                            (not state.expand-tool-results?))]
                            (set state.expand-tool-results? new-val)
                            (state.api.emit
                              {:type :info
                               :text (.. "tool results: "
                                         (if new-val "expanded" "collapsed"))})
                            (paint.invalidate-full!)))})

(api.register :command
              {:name :markdown
               :order 20
               :description "Toggle Markdown rendering of assistant text"
               :handler (fn [args _state]
                          (let [arg (first-arg args)
                                new-val (if (= arg :on) true
                                            (= arg :off) false
                                            (not state.markdown?))]
                            (set state.markdown? new-val)
                            (state.api.emit
                              {:type :info
                               :text (.. "markdown rendering: "
                                         (if new-val "on" "off"))})
                            (paint.invalidate-full!)))})

(api.register :command
              {:name :animations
               :order 25
               :description "Toggle TUI busy animations"
               :handler (fn [args _state]
                          (let [arg (first-arg args)
                                new-val (if (= arg :on) true
                                            (= arg :off) false
                                            (not state.animations?))]
                            (set state.animations? new-val)
                            (set state.spinner-ticks 0)
                            (state.api.emit
                              {:type :info
                               :text (.. "animations: "
                                         (if new-val "on" "off"))})
                            (paint.invalidate!)))})

(api.register :command
              {:name :thinking-blocks
               :order 30
               :description "Show or hide assistant thinking blocks"
               :handler (fn [args _state]
                          (let [arg (first-arg args)
                                ;; User-facing wording is visibility, while
                                ;; state stores hiding.
                                visible? (if (= arg :on) true
                                             (= arg :off) false
                                             state.hide-thinking-block?)
                                hide? (not visible?)]
                            (set state.hide-thinking-block? hide?)
                            (state.api.emit
                              {:type :info
                               :text (.. "thinking blocks: "
                                         (if hide? "hidden" "visible"))})
                            (paint.invalidate-full!)))})

(api.register :command
              {:name :errors
               :order 35
               :description "Toggle recent error details / tracebacks"
               :handler (fn [args _state]
                          (let [arg (first-arg args)]
                            (if (= arg :clear)
                                (do (errors-panel.clear-transcript-errors!)
                                    (state.api.emit {:type :info :text "errors: cleared"})
                                    (paint.invalidate-full!))
                                (let [visible? (errors-panel.toggle!
                                                 (if (= arg :on) true
                                                     (= arg :off) false
                                                     nil))]
                                  (state.api.emit
                                    {:type :info
                                     :text (.. "errors panel: "
                                               (if visible? "on" "off"))})
                                  (paint.invalidate-full!)))))})

(api.register :command
              {:name :redraw
               :order 40
               :description "Force a full terminal repaint to recover from corruption"
               :handler (fn [_args _state]
                          (state.api.emit {:type :hard-refresh}))})

(api.register :introspect
              {:name :runtime
               :description "Current TUI presenter state summary without transcript or input contents"
               :snapshot (fn [_]
                           (let [s state.status-info]
                             {:tb-initialized? state.tb-initialized?
                              :tb-init-failed? state.tb-init-failed?
                              :dimensions {:cols state.tb-cols :rows state.tb-rows}
                              :dirty? state.dirty?
                              :force-redraw? state.force-redraw?
                              :animations? state.animations?
                              :transcript-count (length (or state.transcript []))
                              :streaming-row-count (table-count state.streaming-assistant-rows)
                              :scroll-offset state.scroll-offset
                              :input-bytes (length (or state.input-buf ""))
                              :input-cursor state.input-cursor
                              :paste-active? state.paste-active?
                              :paste-count (table-count state.pastes)
                              :history-count (length (or state.history []))
                              :history-pos state.history-pos
                              :expand-tool-results? state.expand-tool-results?
                              :markdown? state.markdown?
                              :hide-thinking-block? state.hide-thinking-block?
                              :pending-quit? state.pending-quit?
                              :alt-pending? state.alt-pending?
                              :cancel-pressed? state.cancel-pressed?
                              :error-panel-visible? state.error-panel-visible?
                              :status {:provider s.provider
                                       :model s.model
                                       :thinking-status s.thinking-status
                                       :last-input s.last-input
                                       :approx-context s.approx-context
                                       :steering-queued s.steering-queued
                                       :follow-up-queued s.follow-up-queued
                                       :running-label s.running-label
                                       :retrying? s.retrying?
                                       :thinking? s.thinking?
                                       :cancelling? s.cancelling?
                                       :turn-active? (> (or s.turn-start 0) 0)}}))})

  true)

M
