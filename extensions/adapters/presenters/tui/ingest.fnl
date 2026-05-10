;; Bus → transcript ingestion: translate one bus event into transcript
;; appends and `state.status-info` side effects. Extracted from
;; extensions.tui to keep init.fnl focused on lifecycle and registration;
;; this module is the state machine, nothing more.
;;
;; Hot-reload note: in RELOADABLE via the tui manifest. Pure module-table
;; functions; no top-level state of its own — everything lives in
;; `extensions.tui.state` (persistent across reload).

(local state (require :fen.extensions.tui.state))
(local redraw (require :fen.extensions.tui.redraw))
(local paint (require :fen.extensions.tui.paint))
(local transcript (require :fen.extensions.tui.panels.transcript))

(local M {})

(fn clear-render-cache! [ev]
  (transcript.clear-event-render-cache! ev))

(local STREAM-REDRAW-BYTES 128)

(fn stream-key [row-type content-index]
  (.. (tostring row-type) ":" (tostring (or content-index 1))))

(fn find-streaming-assistant-row [row-type content-index]
  (let [rows (or state.streaming-assistant-rows {})]
    (. rows (stream-key row-type content-index))))

(fn materialize-stream-text! [row]
  (when (and row row.text-dirty? row.text-chunks)
    (set row.text (table.concat row.text-chunks ""))
    (set row.text-dirty? false))
  row)

(fn append-assistant-delta! [row-type content-index delta]
  "Append a streaming token. Returns true when the presenter should redraw.
   Tiny deltas are chunked and coalesced so providers that emit token-sized SSE
   events don't force a full Markdown re-render on every token."
  (when (= state.streaming-assistant-rows nil)
    (set state.streaming-assistant-rows {}))
  (let [key (stream-key row-type content-index)
        new? (= (. state.streaming-assistant-rows key) nil)
        row (or (. state.streaming-assistant-rows key)
                (let [ev {:type row-type
                          :text ""
                          :text-chunks []
                          :text-dirty? false
                          :text-version 0
                          :stream-pending-bytes 0
                          :final? false
                          :streaming? true
                          :content-index content-index}]
                  (table.insert state.transcript ev)
                  (tset state.streaming-assistant-rows key ev)
                  ev))
        chunk (or delta "")]
    (when (> (length chunk) 0)
      (table.insert row.text-chunks chunk)
      (set row.text-dirty? true)
      (set row.text-version (+ (or row.text-version 0) 1))
      (set row.stream-pending-bytes (+ (or row.stream-pending-bytes 0)
                                       (length chunk))))
    (let [redraw? (or new? (>= (or row.stream-pending-bytes 0)
                               STREAM-REDRAW-BYTES))]
      (when redraw?
        (set row.stream-pending-bytes 0)
        (clear-render-cache! row))
      redraw?)))

(fn finish-streaming-assistant! [final?]
  (var last nil)
  (each [key ev (pairs (or state.streaming-assistant-rows {}))]
    (when ev.streaming?
      (materialize-stream-text! ev)
      (clear-render-cache! ev)
      (set ev.streaming? nil)
      (set ev.final? false)
      (set ev.stream-pending-bytes 0)
      (set last ev))
    (tset state.streaming-assistant-rows key nil))
  (when last
    (set last.final? final?)))

;; @doc fen.extensions.tui.ingest.append-event
;; kind: function
;; signature: (append-event ev) -> nil
;; summary: Ingest a bus event into transcript rows and TUI status side effects, including streaming coalescing and cache invalidation.
;; tags: tui ingest events transcript status
(fn M.append-event [ev]
  ;; If the user is reading backlog, keep their viewport anchored while
  ;; streamed/appended content grows below it. Without this, a fixed
  ;; scroll-offset is measured from the moving tail, so each new wrapped row
  ;; pulls the viewport downward and makes wheel/PageUp feel like a tug-of-war.
  (let [was-scrolled? (> state.scroll-offset 0)
        before-max (if was-scrolled? (paint.max-scroll) 0)]
    ;; Status-info side effects (don't pollute the transcript).
    (var invalidate? true)
  (if (= ev.type :llm-start)
      (do (set state.status-info.thinking? true)
          (set state.status-info.retrying? false)
          (set state.status-info.retry-attempt 0)
          (set state.status-info.retry-max-attempts 0)
          (set state.status-info.retry-delay-ms 0)
          (set state.status-info.retry-reason nil)
          ;; Stamp the turn start on the first llm-start of a turn
          ;; (turn-start is cleared when a turn completes).
          (when (= (or state.status-info.turn-start 0) 0)
            (set state.status-info.turn-start (os.time))))

      (= ev.type :llm-end)
      (do (set state.status-info.thinking? false)
          (set state.status-info.retrying? false)
          (set state.status-info.retry-attempt 0)
          (set state.status-info.retry-max-attempts 0)
          (set state.status-info.retry-delay-ms 0)
          (set state.status-info.retry-reason nil)
          (when ev.usage
            (let [u ev.usage
                  s state.status-info]
              (set s.cum-input       (+ s.cum-input       (or u.input 0)))
              (set s.cum-output      (+ s.cum-output      (or u.output 0)))
              (set s.cum-cache-read  (+ s.cum-cache-read  (or u.cache-read 0)))
              (set s.cum-cache-write (+ s.cum-cache-write (or u.cache-write 0)))
              (set s.last-input      (or u.input s.last-input)))))

      (= ev.type :provider-retry)
      (let [s state.status-info]
        (set s.retrying? true)
        (set s.retry-attempt (or ev.attempt 0))
        (set s.retry-max-attempts (or ev.max-attempts 0))
        (set s.retry-delay-ms (or ev.delay-ms 0))
        (set s.retry-reason ev.reason))

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
            (set ev.tool-path (?. tc :arguments :path))
            (when tc
              (set tc.paired-result ev)
              (set ev.suppressed? true)
              (clear-render-cache! tc)))
          (table.insert state.transcript ev))

      (= ev.type :cancelled)
      (do (set state.status-info.thinking? false)
          (set state.status-info.retrying? false)
          (set state.status-info.running-label nil)
          (set state.status-info.cancelling? false)
          (set state.status-info.turn-start 0)
          (table.insert state.transcript ev))

      (= ev.type :assistant-text)
      (do (when (not= ev.final? false)
            (set state.status-info.thinking? false)
            (set state.status-info.retrying? false)
            (set state.status-info.running-label nil)
            (set state.status-info.turn-start 0))
          (table.insert state.transcript ev))

      (= ev.type :assistant-thinking)
      (do (when ev.final?
            (set state.status-info.thinking? false)
            (set state.status-info.retrying? false)
            (set state.status-info.running-label nil)
            (set state.status-info.turn-start 0))
          (table.insert state.transcript ev))

      (= ev.type :assistant-text-delta)
      (set invalidate? (append-assistant-delta! :assistant-text ev.content-index ev.delta))

      (= ev.type :assistant-thinking-delta)
      (set invalidate? (append-assistant-delta! :assistant-thinking ev.content-index ev.delta))

      (= ev.type :assistant-stream-end)
      (do (finish-streaming-assistant! ev.final?)
          (when ev.final?
            (set state.status-info.thinking? false)
            (set state.status-info.retrying? false)
            (set state.status-info.running-label nil)
            (set state.status-info.turn-start 0)))

      (= ev.type :error)
      (do (set state.status-info.thinking? false)
          (set state.status-info.retrying? false)
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
    (when (and invalidate? was-scrolled?)
      (let [after-max (paint.max-scroll)
            grew-by (math.max 0 (- after-max before-max))]
        (set state.scroll-offset
             (math.min after-max (+ state.scroll-offset grew-by)))
        (when (> grew-by 0)
          (set state.new-content-below? true))))
    (when (= state.scroll-offset 0)
      (set state.new-content-below? false))
    (when invalidate?
      (redraw.invalidate!))))

M
