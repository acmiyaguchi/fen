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
;;      subscriptions). This is the only file in the TUI extension that
;;      imports `core.extensions`.
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
(local select-mod (require :fen.extensions.tui.select))
(local ingest (require :fen.extensions.tui.ingest))
(local extensions (require :fen.core.extensions))

(local M {})

;; ---------- lifecycle ----------

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
    (tb.set_output_mode tb.OUTPUT_NORMAL)))

(fn M.shutdown []
  (when state.tb-initialized?
    (tb.shutdown)
    (set state.tb-initialized? false)))

(fn M.reset-conversation! []
  "Clear per-conversation TUI state for /new while preserving process/UI
   settings that should survive a fresh session (provider/model, dimensions,
   input history, termbox lifecycle)."
  (paint.ensure-state-defaults!)
  (let [s state.status-info
        provider s.provider
        model s.model]
    (set state.transcript [])
    (set state.scroll-offset 0)
    (set state.input-buf "")
    (set state.input-cursor 0)
    (set state.history-pos 0)
    (set state.history-draft "")
    (set state.pending-quit? false)
    (set s.provider provider)
    (set s.model model)
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
  (paint.redraw!))

(fn M.set-status-info [info]
  "Optional: caller (main.fnl) can populate provider/model on the status
   line. Falls back to nil → '?' rendering otherwise."
  (paint.ensure-state-defaults!)
  (when info.provider (set state.status-info.provider info.provider))
  (when info.model (set state.status-info.model info.model))
  (when info.steering-queued (set state.status-info.steering-queued info.steering-queued))
  (when info.follow-up-queued (set state.status-info.follow-up-queued info.follow-up-queued))
  (when info.approx-context (set state.status-info.approx-context info.approx-context)))

(local TICK-MS 30)

(fn M.run [on-submit on-tick on-cancel is-busy?]
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
    (paint.redraw!)
    (let [(ev err code) (tb.peek_event TICK-MS)]
      (if (and (= ev nil) (= code tb.ERR_NO_EVENT))
          ;; Idle tick. If a bare KEY_ESC fired on a recent event and no
          ;; follow-up arrived within the tick, fire :dismiss so panels
          ;; close. See state.alt-pending? for the rationale.
          (when state.alt-pending?
            (set state.alt-pending? false)
            (extensions.emit {:type :dismiss}))
          (= ev nil)
          (do (ingest.append-event
                {:type :error
                 :error (.. "tb_peek_event failed: " (tostring err))})
              (set quit? true))
          (let [(ok? r) (pcall input.handle-event ev on-submit on-cancel is-busy?)]
            (if (not ok?)
                (ingest.append-event {:type :error
                                 :error (.. "tui: " (tostring r))})
                r
                (set quit? true))))
      (when (and (not quit?) on-tick)
        (let [(ok? err) (pcall on-tick)]
          (when (not ok?)
            (ingest.append-event {:type :error
                             :error (.. "on-tick: " (tostring err))})))))
    ;; Once the agent turn finishes (the coroutine no longer reports busy)
    ;; clear any first-press cancel state so the next ctrl-c arms a quit
    ;; rather than landing on a stale "cancel pressed" branch that could
    ;; force-quit on the next one. Status indicator is cleared by
    ;; append-event when :cancelled fires; this mop-up handles the case
    ;; where the turn completed normally between presses.
    (when (and state.cancel-pressed? is-busy? (not (is-busy?)))
      (set state.cancel-pressed? false)
      (set state.status-info.cancelling? false))))

;; -----------------------------------------------------------------
;; Extension registration (issue #15, Step 3b/3c)
;; -----------------------------------------------------------------
;;
;; The TUI registers as a presenter and owns its TUI-coupled slash
;; commands (/expand, /markdown, /thinking). Other commands like /new
;; and /reload reach the TUI through bus events instead of direct calls,
;; keeping the contract one-way: outside code emits, the TUI subscribes.
;;
;; Reload-safe: this module is in RELOADABLE; manual-reload! re-runs
;; this block on every /reload. unregister-by-owner :tui drops the
;; prior batch first so subscriptions and registrations don't double up.

(extensions.unregister-by-owner :tui)
(local api (extensions.make-api :tui))

;; The TUI is the active presenter — every event emitted on the bus
;; lands in the transcript via append-event, EXCEPT presenter-control
;; events that have their own dedicated subscribers below (clearing
;; the transcript or redrawing is not transcript content).
(local PRESENTER-CONTROL-EVENTS
  {:reset-conversation true
   :reinit-presenter true
   :redraw true
   :set-status-info true})

(api.on :*
        (fn [ev]
          (when (not (. PRESENTER-CONTROL-EVENTS ev.type))
            (ingest.append-event ev))))

;; Bus events that ask the TUI to do something. Built-in commands
;; (/new, /reload) emit these instead of importing the TUI module.
(api.on :reset-conversation
        (fn [_] (M.reset-conversation!)))
(api.on :reinit-presenter
        (fn [_] (M.init!)))
(api.on :redraw
        (fn [_] (paint.force-redraw!)))
(api.on :set-status-info
        (fn [ev] (M.set-status-info (or ev.info {}))))

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
                           {:text (.. "scrolled:" (tostring state.scroll-offset))
                            :style :status}))})

;; First-party panels. Busy row is the only one in v1; lives above input
;; with order 10 (closest to the input box). Collapses to height 0 when
;; idle so the row goes back to the transcript.
(api.register :panel (busy-panel.spec))

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
                      (M.run ctx.on-submit ctx.on-tick
                             ctx.request-cancel ctx.is-busy?))
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
                            (extensions.emit
                              {:type :info
                               :text (.. "tool results: "
                                         (if new-val "expanded" "collapsed"))})))})

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
                            (extensions.emit
                              {:type :info
                               :text (.. "markdown rendering: "
                                         (if new-val "on" "off"))})
                            (paint.redraw!)))})

(api.register :command
              {:name :thinking
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
                            (extensions.emit
                              {:type :info
                               :text (.. "thinking blocks: "
                                         (if hide? "hidden" "visible"))})
                            (paint.redraw!)))})

M
