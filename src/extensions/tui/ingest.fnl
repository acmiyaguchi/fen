;; Bus → transcript ingestion: translate one bus event into transcript
;; appends and `state.status-info` side effects. Extracted from
;; extensions.tui to keep init.fnl focused on lifecycle and registration;
;; this module is the state machine, nothing more.
;;
;; Hot-reload note: in RELOADABLE via the tui manifest. Pure module-table
;; functions; no top-level state of its own — everything lives in
;; `extensions.tui.state` (persistent across reload).

(local state (require :extensions.tui.state))
(local paint (require :extensions.tui.paint))
(local transcript (require :extensions.tui.panels.transcript))

(local M {})

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
          (set ev.short (transcript.tool-call-short ev.name ev.arguments))
          (set ev.args-pretty (transcript.args->string ev.arguments))
          ;; running-label drives the busy indicator row. Prefer the
          ;; short form (which includes the path/cmd for built-ins) over
          ;; the bare tool name.
          (set state.status-info.running-label
               (or ev.short (tostring ev.name)))
          (table.insert state.transcript ev))

      (= ev.type :tool-result)
      (do (set state.status-info.running-label nil)
          (let [text (transcript.content->text (?. ev :result :content))
                tc (transcript.lookup-tool-call ev.id)]
            (set ev.body-bytes (length text))
            (set ev.body-lines (transcript.count-lines text))
            (set ev.body-pretty (transcript.truncate text transcript.TOOL-RESULT-PREVIEW-BYTES))
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

M
