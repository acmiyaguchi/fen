;; TUI presenter lifecycle and extension registration.
;; Hot reload: helpers dispatch through `M.<name>`; mutable state lives in non-reloaded modules.
;; Termbox2 diffs internally, so every redraw does a full clear/repaint/present.

(local state (require :fen.extensions.tui.state))
(local tb (require :termbox2))
(local paint (require :fen.extensions.tui.paint))
(local input (require :fen.extensions.tui.input))
(local transcript (require :fen.extensions.tui.panels.transcript))
(local workspaces (require :fen.extensions.tui.workspaces))
(local side-chat (require :fen.extensions.tui.side_chat))
(local tabs-panel (require :fen.extensions.tui.panels.tabs))
(local busy-panel (require :fen.extensions.tui.panels.busy))
(local errors-panel (require :fen.extensions.tui.panels.errors))
(local select-mod (require :fen.extensions.tui.select))
(local completion (require :fen.extensions.tui.completion))
(local ingest (require :fen.extensions.tui.ingest))
(local log (require :fen.util.log))
(local log-sink (require :fen.util.log_sink))
(local path (require :fen.util.path))
(local clock (require :fen.util.clock))
(local first-arg (. (require :fen.util.args) :first-arg))

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

(fn M.mouse-enabled? []
  "Mouse capture is on by default so the wheel scrolls the transcript.
   Enabling SGR mouse reporting makes the terminal forward click and drag
   to fen instead of doing its own text selection, so selecting transcript
   text to copy stops working. Set FEN_TUI_MOUSE to a falsey value
   (0/off/false/no, case-insensitive) to turn capture off and restore
   native terminal selection — and thus copy/paste out of a session — at
   the cost of mouse-wheel scrolling (Page Up/Page Down still scroll)."
  (let [raw (os.getenv :FEN_TUI_MOUSE)]
    (if (= raw nil)
        true
        (let [v (string.lower raw)]
          (not (or (= v "0") (= v "off") (= v "false") (= v "no") (= v "")))))))

(fn M.input-mode []
  "INPUT_ESC always (bare Esc surfaces immediately; input.fnl synthesizes
   MOD_ALT for Alt combos). INPUT_MOUSE is added only when mouse capture is
   enabled — omitting it makes tb.set_input_mode emit the SGR-disable
   sequence, restoring the terminal's own selection behavior."
  (if (M.mouse-enabled?)
      (bor tb.INPUT_ESC tb.INPUT_MOUSE)
      tb.INPUT_ESC))

(fn M.init! []
  "Initialize termbox2 (gated by tb-initialized? — runs at most once per
   process) and apply runtime config (idempotent — runs on every call so
   /reload can pick up new input/output mode flags or other runtime
   settings without a process restart). The /reload built-in command
   invokes this after re-requiring extensions.tui."
  (paint.ensure-state-defaults!)
  (workspaces.ensure!)
  (when (not state.tb-initialized?)
    (let [(rc _err _code) (tb.init)]
      (if (and rc (>= rc 0))
          (do (set state.tb-initialized? true)
              (set state.tb-init-failed? false)
              (when (= state.status-info.start-ms 0)
                (set state.status-info.start-ms (os.time))))
          (set state.tb-init-failed? true))))
  (when state.tb-initialized?
    ;; Reroute log.* to a file first: once termbox owns the terminal, stderr writes corrupt the frame.
    (open-log-sink!)
    (set state.tb-cols (tb.width))
    (set state.tb-rows (tb.height))
    ;; set_input_mode emits SGR escapes immediately; new C-shim symbols still need a process restart.
    (tb.set_input_mode (M.input-mode))
    ;; Bracketed paste: pasted newlines must not look like Enter-submit keystrokes.
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
    (io.write "\27[?2004l")
    (io.flush)
    (tb.shutdown)
    (set state.tb-initialized? false)
    ;; Stderr is the terminal again — release the sink so trailing log lines reach the user.
    (log-sink.close!))
  (set state.presenter-ctx nil))

(fn M.hard-refresh! []
  "Recover the screen after external terminal interference (another process
   writing to the tty, tmux/resize glitches, front-buffer desync). M.init!'s
   idempotent path re-asserts input/output modes and bracketed paste; force-redraw!
   then blank-presents to invalidate termbox's front buffer and repaints. Scroll
   position and input buffer live in persistent state, so both are preserved."
  (M.init!)
  (paint.force-redraw!))

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

(fn M.reset-conversation! []
  "Clear per-conversation TUI state for /new while preserving process/UI
   settings that should survive a fresh session (provider/model, dimensions,
   input history, termbox lifecycle)."
  (paint.ensure-state-defaults!)
  ;; /new resets the interactive main session, never a read-only job tab.
  (workspaces.activate! :main-session)
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
    (set s.approx-context 0)
    (set s.context-estimated? true)
    (set s.context-source :estimated)
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
  (workspaces.capture-active!)
  (paint.invalidate-full!))

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
  (when (not= info.approx-context nil)
    (set state.status-info.approx-context info.approx-context))
  (when (not= info.context-estimated? nil)
    (set state.status-info.context-estimated? info.context-estimated?))
  (when info.context-source
    (set state.status-info.context-source info.context-source))
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

;; Cache optional profiler lookups off the hot path; reloading this module resets a cached miss.
(var profile-state nil)
(var profile-state-resolved? false)
(var profile-activity nil)
(var profile-activity-resolved? false)

(fn cached-profile-state []
  (when (not profile-state-resolved?)
    (set profile-state-resolved? true)
    (let [(ok? profiler) (pcall require :fen.extensions.profiler.state)]
      (when ok? (set profile-state profiler))))
  profile-state)

(fn cached-profile-activity []
  (when (not profile-activity-resolved?)
    (set profile-activity-resolved? true)
    (let [(ok? activity) (pcall require :fen.extensions.profiler.activity)]
      (when ok? (set profile-activity activity))))
  profile-activity)

(fn profile-enabled? []
  (let [profiler (cached-profile-state)]
    (and profiler profiler.enabled?)))

(fn record-profile-wall-gap! [phase elapsed start-cpu]
  "Best-effort dev-profiler seam: the TUI remains usable when that optional
   extension is absent, while an active capture receives structured measured
   wall-gap evidence for opaque/native work inside input or tick resumes."
  (when (profile-enabled?)
    (pcall (. (cached-profile-state) :record-wall-gap!)
           {:source :tui
            :phase phase
            :wall-ms elapsed
            :cpu-ms (* 1000 (- (os.clock) start-cpu))
            :opaque? true
            :budget-exceeded? (>= elapsed (stall-warn-ms))})))

(fn profile-span-begin! [name metadata]
  (when (profile-enabled?)
    (let [(recorded? token) (pcall (. (cached-profile-activity) :span-begin!) name metadata)]
      (if recorded? token nil))))

(fn profile-span-end! [token]
  (when (and token (profile-enabled?))
    (pcall (. (cached-profile-activity) :span-end!) token)))

(fn profile-counter-add! [name]
  (when (profile-enabled?)
    (pcall (. (cached-profile-activity) :counter-add!) name)))

(fn M.warn-if-stalled! [phase start-ms ?get-turn ?ev ?start-cpu]
  (let [threshold (stall-warn-ms)
        now (clock.monotonic-ms)
        elapsed (- now start-ms)]
    (when (profile-enabled?)
      (record-profile-wall-gap! phase elapsed (or ?start-cpu (os.clock))))
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

(fn M.peek-timeout-ms [is-busy?]
  "Use a short poll while busy or resolving Esc/Alt, but sleep longer when the
   TUI is clean and idle. Dirty redraw already prevents repaint churn; this
   prevents a 33Hz no-op wakeup loop on slow/battery-constrained terminals."
  (if (or state.dirty?
          state.force-redraw?
          state.alt-pending?
          (and is-busy? (is-busy?))
          (side-chat.busy?)
          (paint.busy?))
      ACTIVE-TICK-MS
      IDLE-TICK-MS))

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

(local MAX-SCROLL-BURST-EVENTS 64)

;; @doc fen.extensions.tui.scroll-event?
;; kind: function
;; signature: (scroll-event? ev) -> boolean
;; summary: Return whether a termbox event moves the transcript viewport.
;; tags: tui input scroll performance
(fn M.scroll-event? [ev]
  (or (and (= ev.type tb.EVENT_MOUSE)
           (or (= ev.key tb.KEY_MOUSE_WHEEL_UP)
               (= ev.key tb.KEY_MOUSE_WHEEL_DOWN)))
      (and (= ev.type tb.EVENT_KEY)
           (or (= ev.key tb.KEY_PGUP) (= ev.key tb.KEY_PGDN)))))

(fn M.guard-tick! [label f]
  "Run a cooperative per-tick worker without letting it terminate the TUI."
  (let [(ok? err) (xpcall f debug.traceback)]
    (when (not ok?)
      (state.api.emit {:type :error
                       :error (.. label ": " (first-line err))
                       :traceback (tostring err)}))))

(fn M.drain-scroll-burst! [first-event handle]
  "Handle FIRST-EVENT and coalesce an immediately queued scroll burst. The
   first non-scroll event after a burst is also handled because termbox has no
   push-back operation. Bounded draining preserves agent tick responsiveness."
  (var ev first-event)
  (var count 0)
  (var quit? false)
  (var err nil)
  (var continue? true)
  (while (and ev continue? (not quit?) (< count MAX-SCROLL-BURST-EVENTS))
    (let [scroll? (M.scroll-event? ev)]
      (set quit? (not (not (handle ev))))
      (set count (+ count 1))
      (if (and scroll? (not quit?) (< count MAX-SCROLL-BURST-EVENTS))
          (let [(next-ev next-err code) (tb.peek_event 0)]
            (if next-ev
                (set ev next-ev)
                (or (= code tb.ERR_NO_EVENT) (M.interrupted-syscall? next-err))
                (do (set ev nil) (set continue? false))
                (do (set err (.. "tb_peek_event failed: " (tostring next-err)))
                    (set ev nil)
                    (set continue? false))))
          (set continue? false))))
  (values quit? count err))

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
  (set state.on-tick on-tick)
  (workspaces.with-main!
    #(ingest.append-event
       {:type :info
        :text "fen — ctrl-d to quit, ctrl-c twice to quit, ctrl-j for newline"}))
  (var quit? false)
  (while (not quit?)
    (if (profile-enabled?)
        (let [paint-span (profile-span-begin! :tui-paint {})]
          (paint.advance-spinner-if-due!)
          (paint.redraw-if-needed!)
          (profile-span-end! paint-span)
          (profile-counter-add! :tui-paint-attempts))
        (do
          (paint.advance-spinner-if-due!)
          (paint.redraw-if-needed!)))
    (let [(ev err code) (tb.peek_event (M.peek-timeout-ms is-busy?))]
      (if (and (= ev nil)
               (or (= code tb.ERR_NO_EVENT)
                   ;; EINTR is transient — treat as an idle tick, never session-fatal (#132).
                   (M.interrupted-syscall? err)))
          ;; Idle tick: fire :dismiss when a bare Esc got no follow-up (see state.alt-pending?).
          (when state.alt-pending?
            (set state.alt-pending? false)
            (state.api.emit {:type :dismiss}))
          (= ev nil)
          (do (state.api.emit
                {:type :error
                 :error (.. "tb_peek_event failed: " (tostring err))})
              (set quit? true))
          (let [handle-one
                (fn [input-ev]
                  (let [profiling? (profile-enabled?)
                        start-ms (clock.monotonic-ms)
                        start-cpu (and profiling? (os.clock))
                        span (and profiling?
                                  (profile-span-begin! :tui-input {:event-type input-ev.type}))
                        (ok? r) (xpcall #(input.handle-event input-ev on-submit on-cancel is-busy?)
                                         debug.traceback)]
                    (when profiling?
                      (profile-span-end! span)
                      (profile-counter-add! :tui-input-events))
                    (M.warn-if-stalled! :input start-ms ?get-turn input-ev start-cpu)
                    (if (not ok?)
                        (do (state.api.emit {:type :error
                                             :error (.. "tui: " (first-line r))
                                             :traceback (tostring r)})
                            false)
                        r)))
                (batch-quit? _ batch-err) (M.drain-scroll-burst! ev handle-one)]
            (when batch-err
              (state.api.emit {:type :error :error batch-err})
              (set quit? true))
            (when batch-quit?
              (set quit? true)))))
      (when (and (not quit?) on-tick)
        (let [profiling? (profile-enabled?)
              start-ms (clock.monotonic-ms)
              start-cpu (and profiling? (os.clock))
              span (and profiling? (profile-span-begin! :tui-tick {}))
              (ok? err) (xpcall on-tick debug.traceback)]
          (when profiling?
            (profile-span-end! span)
            (profile-counter-add! :tui-ticks))
          (M.warn-if-stalled! :tick start-ms ?get-turn nil start-cpu)
          (when (not ok?)
            (state.api.emit {:type :error
                              :error (.. "on-tick: " (first-line err))
                              :traceback (tostring err)}))))
      ;; Side chat and detached subagents share this cooperative tick so they stream alongside the main turn.
      (when (not quit?)
        (M.guard-tick! "side-chat.tick!" side-chat.tick!))
      (when (not quit?)
        (M.guard-tick! "workspaces.sync-subagents!" workspaces.sync-subagents!))
    ;; Clear stale first-press cancel state when the turn ends normally, so the next ctrl-c arms quit, not force-quit.
    (when (and state.cancel-pressed? is-busy? (not (is-busy?)))
      (set state.cancel-pressed? false)
      (set state.status-info.cancelling? false)
      (paint.invalidate!))))

;; Reload-safe: the loader drops the prior owner-tagged batch before re-requiring, so registrations don't double.
(fn M.register [api]
  (set state.api api)

;; Every bus event lands in the transcript EXCEPT presenter-control events with dedicated subscribers below.
(local PRESENTER-CONTROL-EVENTS
  {:runtime-tick true
   :model-catalog-updated true
   :agent-turn-complete true
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
            (workspaces.with-main! #(ingest.append-event ev)))))

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
(api.on :model-catalog-updated
        (fn [_]
          ;; Dynamic model discovery may finish while the input bytes/cursor are
          ;; unchanged. Bypass the snapshot guard and rebuild inline choices.
          (completion.invalidate!)
          (completion.refresh! (or state.presenter-ctx {}))
          (paint.invalidate-full!)))
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
(fn active-agent-workspace []
  (let [(ok? ws) (pcall workspaces.active)]
    (when (and ok? (workspaces.agent? ws)
               (not= ws.kind :main-session))
      ws)))

(fn numeric [v]
  (and (= (type v) :number) v))

(fn workspace-usage-total [usage]
  (when usage
    (or (numeric (. usage :total-tokens))
        (and (or (numeric usage.input) (numeric usage.output))
             (+ (or (numeric usage.input) 0)
                (or (numeric usage.output) 0))))))

(api.register :status
              {:name :model
               :side :left
               :order 10
               :render (fn [_ctx]
                         (let [ws (active-agent-workspace)]
                           (if ws
                               {:text (.. (or ws.provider "?") ":"
                                          (tostring (or ws.model "?")))
                                :style :status}
                               (let [s state.status-info]
                                 {:text (.. (or s.provider "?") ":" (tostring (or s.model "?")))
                                  :style :status}))))})

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
                         (let [ws (active-agent-workspace)]
                           (if ws
                               (let [total (workspace-usage-total ws.usage)]
                                 {:text (.. "tok:"
                                            (if total
                                                (paint.fmt-tokens total)
                                                "?"))
                                  :style :status})
                               (let [s state.status-info]
                                 {:text (.. "ctx:"
                                           (if (= s.context-estimated? false) "" "~")
                                           (paint.fmt-tokens (or s.approx-context s.last-input)))
                                  :style :status}))))})

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

;; Transient copy feedback after a mouse-selection OSC 52 copy. Shows for a
;; few seconds then clears itself so it doesn't pin the status line.
(local COPY-STATUS-TTL-SECONDS 4)
(api.register :status
              {:name :copy
               :side :left
               :order 70
               :render (fn [_ctx]
                         (let [cs state.copy-status]
                           (when cs
                             (if (> (- (os.time) (or cs.at-seconds 0)) COPY-STATUS-TTL-SECONDS)
                                 (do (set state.copy-status nil) nil)
                                 (let [text (if cs.ok?
                                                (.. "copied " (tostring (or cs.bytes 0)) "B")
                                                (= cs.reason :too-large)
                                                "copy: too large"
                                                (= cs.reason :write-error)
                                                "copy failed"
                                                "")]
                                   (when (not= text "")
                                     {:text text :style :status}))))))})

(api.register :status
              {:name :errors
               :side :right
               :order 90
               :render (fn [_ctx]
                         (when (and (not (errors-panel.visible?))
                                    (errors-panel.has-errors?))
                           {:text "err:/errors"
                            :style :error}))})

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
(api.register :panel (tabs-panel.spec))
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
               ;; The TUI run loop calls on-tick while idle, so detached
               ;; background subagent jobs are pumped and reaped here.
               :idle-ticks? true
               :init (fn [_ctx] (M.init!))
               :shutdown (fn [_ctx] (M.shutdown))
               :run (fn [ctx]
                      ;; Keep the presenter ctx available to input-time completers without widening input's dispatch signature.
                      (set state.presenter-ctx ctx)
                      (M.run ctx.on-submit ctx.on-tick
                             ctx.request-cancel ctx.is-busy?
                             ctx.get-turn))
               :ui {:notify (fn [text _opts]
                              (workspaces.with-main!
                                #(ingest.append-event
                                   {:type :info :text (tostring text)})))
                    :prompt (fn [_opts] nil)
                    :select (fn [opts] (select-mod.tui-select opts))}})

(api.register :control
              {:name :next-workspace
               :keys ["alt-right"]
               :order 2
               :description "Switch to the next presenter tab"})

(api.register :control
              {:name :previous-workspace
               :keys ["alt-left"]
               :order 3
               :description "Switch to the previous presenter tab"})

(api.register :control
              {:name :list-workspaces
               :keys ["alt-t"]
               :order 4
               :description "Open the tab list and switch with the modal selector"})

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
              {:name :btw
               :order 5
               :usage "/btw [initial message]"
               :description "Open or focus an ephemeral read-only side-agent chat"
               :handler (fn [args run-state]
                          (side-chat.open! run-state args))})

(api.register :command
              {:name :btw-use
               :order 6
               :usage "/btw-use"
               :description "Copy the btw agent's last reply into the main input draft"
               :handler (fn [args _run-state]
                          (if (string.find (or args "") "%S")
                              (workspaces.append-active!
                                {:type :error :error "usage: /btw-use"})
                              (let [(ok? err) (side-chat.use-last!)]
                                (when (not ok?)
                                  (workspaces.append-active!
                                    {:type :error :error err})))))})

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
                                ;; User-facing wording is visibility; state stores hiding.
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
                              :mouse-enabled? (M.mouse-enabled?)
                              :workspace-count (length (workspaces.list))
                              :active-workspace-id state.active-workspace-id
                              :selection-active? (not= state.selection nil)
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
                                       :context-estimated? s.context-estimated?
                                       :context-source s.context-source
                                       :steering-queued s.steering-queued
                                       :follow-up-queued s.follow-up-queued
                                       :running-label s.running-label
                                       :retrying? s.retrying?
                                       :thinking? s.thinking?
                                       :cancelling? s.cancelling?
                                       :turn-active? (> (or s.turn-start 0) 0)}}))})

  true)

M
