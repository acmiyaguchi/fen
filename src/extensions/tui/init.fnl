;; TUI presenter extension: the litmus test for the issue #15 api.
;;
;; Layout (top to bottom):
;;   row 0      status line: provider:model | ctx:N | busy:tool | scrolled:N
;;   row 1..    transcript region (scrollable; auto-tails unless scrolled up)
;;   row H-K..  multi-line input box (K rows; grows with newlines, capped)
;;
;; Step 3d split: rendering moved to `extensions.tui.paint`; input handling
;; moved to `extensions.tui.input`. This file owns three things:
;;
;;   1. The bus → state machine (M.append-event) that translates events
;;      arriving on the api event bus into transcript appends and
;;      status-info side effects.
;;   2. Lifecycle: init!, shutdown, run, reset-conversation!,
;;      set-status-info — main.fnl drives these for bootstrap/teardown.
;;   3. The extension-registration block (presenter, command, and event
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

(local state (require :extensions.tui.state))
(local tb (require :termbox2))
(local paint (require :extensions.tui.paint))
(local input (require :extensions.tui.input))
(local extensions (require :core.extensions))

(local M {})

;; ---------- re-exports for external callers and tests ----------
;;
;; Callers outside the TUI (main.fnl, tests) reach for `tui.X` via
;; (require :extensions.tui). To avoid making every caller learn the new
;; submodule layout, re-export the public surface of paint/input on M.
;; Both submodules are in RELOADABLE so when /reload re-runs THIS body
;; the references re-bind to the latest paint/input functions.

(set M.ensure-state-defaults! paint.ensure-state-defaults!)
(set M.viewport-lines paint.viewport-lines)
(set M.max-scroll paint.max-scroll)
(set M.layout paint.layout)
(set M.input-rows paint.input-rows)
(set M.spin-char paint.spin-char)
(set M.turn-elapsed paint.turn-elapsed)
(set M.paint-status paint.paint-status)
(set M.paint-busy paint.paint-busy)
(set M.paint-transcript paint.paint-transcript)
(set M.paint-input paint.paint-input)
(set M.redraw! paint.redraw!)
(set M.clear-render-caches! paint.clear-render-caches!)
(set M.force-redraw! paint.force-redraw!)

(set M.handle-key input.handle-key)
(set M.handle-mouse input.handle-mouse)
(set M.handle-event input.handle-event)

;; ---------- event ingestion (state machine) ----------
;;
;; append-event translates a single bus event into transcript appends
;; and status-info side effects. It is the bridge between the bus
;; (whose events have free-form types) and the transcript (whose entries
;; need cached formatting fields like body-bytes/body-lines/short).

(fn clear-render-cache! [ev]
  (set ev.md-cache-lines nil)
  (set ev.md-cache-width nil))

(fn find-streaming-assistant-row [row-type content-index]
  (var found nil)
  (var i (length state.transcript))
  (while (and (> i 0) (not found))
    (let [ev (. state.transcript i)]
      (if (and ev ev.streaming? (= ev.type row-type)
               (= ev.content-index content-index))
          (set found ev)
          ;; Stop searching once we've crossed into an older assistant/tool/user
          ;; group. This keeps interleaved future events from mutating stale rows.
          (and ev (not ev.streaming?)
               (or (= ev.type :assistant-text)
                   (= ev.type :assistant-thinking)
                   (= ev.type :tool-call)
                   (= ev.type :tool-result)
                   (= ev.type :user)))
          (set i 0)))
    (set i (- i 1)))
  found)

(fn append-assistant-delta! [row-type content-index delta]
  (let [row (or (find-streaming-assistant-row row-type content-index)
                (let [ev {:type row-type
                          :text ""
                          :final? false
                          :streaming? true
                          :content-index content-index}]
                  (table.insert state.transcript ev)
                  ev))]
    (set row.text (.. (or row.text "") (or delta "")))
    (clear-render-cache! row)))

(fn finish-streaming-assistant! [final?]
  (var last nil)
  (each [_ ev (ipairs state.transcript)]
    (when ev.streaming?
      (set ev.streaming? nil)
      (set ev.final? false)
      (set last ev)))
  (when last
    (set last.final? final?)))

(fn M.append-event [ev]
  (paint.ensure-state-defaults!)
  ;; If the user is reading backlog, keep their viewport anchored while
  ;; streamed/appended content grows below it. Without this, a fixed
  ;; scroll-offset is measured from the moving tail, so each new wrapped row
  ;; pulls the viewport downward and makes wheel/PageUp feel like a tug-of-war.
  (let [was-scrolled? (> state.scroll-offset 0)
        before-max (if was-scrolled? (paint.max-scroll) 0)]
    ;; Status-info side effects (don't pollute the transcript).
  (if (= ev.type :llm-start)
      (do (set state.status-info.thinking? true)
          ;; Stamp the turn start on the first llm-start of a turn
          ;; (turn-start is cleared when a turn completes).
          (when (= (or state.status-info.turn-start 0) 0)
            (set state.status-info.turn-start (os.time))))

      (= ev.type :llm-end)
      (do (set state.status-info.thinking? false)
          (when ev.usage
            (let [u ev.usage
                  s state.status-info]
              (set s.cum-input       (+ s.cum-input       (or u.input 0)))
              (set s.cum-output      (+ s.cum-output      (or u.output 0)))
              (set s.cum-cache-read  (+ s.cum-cache-read  (or u.cache-read 0)))
              (set s.cum-cache-write (+ s.cum-cache-write (or u.cache-write 0)))
              (set s.last-input      (or u.input s.last-input)))))

      (= ev.type :tool-call)
      (do
          ;; Compute the tailored short form for known built-ins; fall
          ;; back to JSON args for anything else. args-pretty stays as a
          ;; safety net the renderer still consults.
          (set ev.short (paint.tool-call-short ev.name ev.arguments))
          (set ev.args-pretty (paint.args->string ev.arguments))
          ;; running-label drives the busy indicator row. Prefer the
          ;; short form (which includes the path/cmd for built-ins) over
          ;; the bare tool name.
          (set state.status-info.running-label
               (or ev.short (tostring ev.name)))
          (table.insert state.transcript ev))

      (= ev.type :tool-result)
      (do (set state.status-info.running-label nil)
          (let [text (paint.content->text (?. ev :result :content))
                tc (paint.lookup-tool-call ev.id)]
            (set ev.body-bytes (length text))
            (set ev.body-lines (paint.count-lines text))
            (set ev.body-pretty (paint.truncate text paint.TOOL-RESULT-PREVIEW-BYTES))
            (set ev.tool-name (or ev.name (?. tc :name)))
            (set ev.tool-path (?. tc :arguments :path)))
          (table.insert state.transcript ev))

      (= ev.type :cancelled)
      (do (set state.status-info.thinking? false)
          (set state.status-info.running-label nil)
          (set state.status-info.cancelling? false)
          (set state.status-info.turn-start 0)
          (table.insert state.transcript ev))

      (= ev.type :assistant-text)
      (do (when (not= ev.final? false)
            (set state.status-info.thinking? false)
            (set state.status-info.running-label nil)
            (set state.status-info.turn-start 0))
          (table.insert state.transcript ev))

      (= ev.type :assistant-thinking)
      (do (when ev.final?
            (set state.status-info.thinking? false)
            (set state.status-info.running-label nil)
            (set state.status-info.turn-start 0))
          (table.insert state.transcript ev))

      (= ev.type :assistant-text-delta)
      (append-assistant-delta! :assistant-text ev.content-index ev.delta)

      (= ev.type :assistant-thinking-delta)
      (append-assistant-delta! :assistant-thinking ev.content-index ev.delta)

      (= ev.type :assistant-stream-end)
      (do (finish-streaming-assistant! ev.final?)
          (when ev.final?
            (set state.status-info.thinking? false)
            (set state.status-info.running-label nil)
            (set state.status-info.turn-start 0)))

      (= ev.type :error)
      (do (set state.status-info.thinking? false)
          (set state.status-info.running-label nil)
          (set state.status-info.turn-start 0)
          (table.insert state.transcript ev))

      (= ev.type :extension-loaded)
      ;; Normalize loader diagnostics at append time so they survive renderer
      ;; reloads/forced redraws as ordinary transcript info rows.
      (table.insert state.transcript
                    {:type :info
                     :text (.. "extension-loaded: "
                               (tostring (or ev.name "")))})

      ;; user / queued / injected / unknown — just append.
      (table.insert state.transcript ev))
    (when was-scrolled?
      (let [after-max (paint.max-scroll)
            grew-by (math.max 0 (- after-max before-max))]
        (set state.scroll-offset
             (math.min after-max (+ state.scroll-offset grew-by))))))
  (paint.redraw!))

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
    ;; INPUT_ALT collapses ESC+key into one event with MOD_ALT.
    ;; INPUT_MOUSE enables SGR mouse reporting (mode 1006), which tmux
    ;; forwards to the foreground pane when `set -g mouse on`.
    (tb.set_input_mode (bor tb.INPUT_ALT tb.INPUT_MOUSE))
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
  (when info.follow-up-queued (set state.status-info.follow-up-queued info.follow-up-queued)))

(local TICK-MS 30)

(fn M.run [on-submit on-tick on-cancel is-busy?]
  (when state.tb-init-failed?
    (io.stderr:write
      "fen: termbox2 init failed (TUI requires an interactive terminal)\n")
    (os.exit 1))
  (M.append-event
    {:type :info
     :text "fen — ctrl-d to quit, ctrl-c twice to quit, ctrl-j for newline"})
  (var quit? false)
  (while (not quit?)
    (paint.redraw!)
    (let [(ev err code) (tb.peek_event TICK-MS)]
      (if (and (= ev nil) (= code tb.ERR_NO_EVENT))
          nil
          (= ev nil)
          (do (M.append-event
                {:type :error
                 :error (.. "tb_peek_event failed: " (tostring err))})
              (set quit? true))
          (let [(ok? r) (pcall input.handle-event ev on-submit on-cancel is-busy?)]
            (if (not ok?)
                (M.append-event {:type :error
                                 :error (.. "tui: " (tostring r))})
                r
                (set quit? true))))
      (when (and (not quit?) on-tick)
        (let [(ok? err) (pcall on-tick)]
          (when (not ok?)
            (M.append-event {:type :error
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
            (M.append-event ev))))

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
                         {:text (.. "ctx:" (paint.fmt-tokens state.status-info.last-input))
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
                              (M.append-event
                                {:type :info :text (tostring text)}))
                    :prompt (fn [_opts] nil)
                    :select (fn [_opts] nil)}})

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
