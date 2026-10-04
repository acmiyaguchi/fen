;; Bus -> transcript ingestion state machine; reloadable, no state of its own (all in extensions.tui.state).

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

(fn running-tool-label []
  (var n 0)
  (var only-label nil)
  (each [_ label (pairs (or state.status-info.running-tools {}))]
    (set n (+ n 1))
    (set only-label label))
  (if (= n 0) nil
      (= n 1) only-label
      (.. n " tools")))

(fn refresh-running-label! []
  (set state.status-info.running-label (running-tool-label)))

(fn track-running-tool! [id label]
  (if id
      (do
        (when (= state.status-info.running-tools nil)
          (set state.status-info.running-tools {}))
        (tset state.status-info.running-tools (tostring id) label)
        (refresh-running-label!))
      (set state.status-info.running-label label)))

(fn untrack-running-tool! [id]
  (when (and id state.status-info.running-tools)
    (tset state.status-info.running-tools (tostring id) nil)
    (refresh-running-label!)))

(fn clear-running-tools! []
  (set state.status-info.running-tools nil)
  (set state.status-info.running-label nil))

;; Server-executed (hosted) tools: a busy label while running, one info row when done.
(local HOSTED-TOOL-LABELS
  {:web_search {:running "searching the web" :done "web search"}})

(local HOSTED-TOOL-PREFIX "hosted-tool:")

(fn hosted-tool-key [ev]
  (.. HOSTED-TOOL-PREFIX (tostring (or ev.id ev.name ""))))

(fn clear-hosted-tools! []
  "Drop running hosted tools: none outlives the provider attempt that started it,
   and a retried stream may never send the end for a search it cut off."
  (let [running state.status-info.running-tools]
    (var removed? false)
    (each [key (pairs (or running {}))]
      (when (= (string.sub (tostring key) 1 (length HOSTED-TOOL-PREFIX))
               HOSTED-TOOL-PREFIX)
        (tset running key nil)
        (set removed? true)))
    (when removed?
      (refresh-running-label!))))

(fn hosted-tool-label [ev which]
  (or (?. HOSTED-TOOL-LABELS (tostring ev.name) which)
      (tostring (or ev.name "hosted tool"))))

(fn hosted-tool-row [ev]
  (let [label (hosted-tool-label ev :done)
        marked (if (or (= ev.status nil) (= ev.status :completed))
                   label
                   (.. label " " (tostring ev.status)))]
    {:type :info
     :text (if ev.detail (.. marked ": " (tostring ev.detail)) marked)}))

;; @doc fen.extensions.tui.ingest.append-event
;; kind: function
;; signature: (append-event ev ?opts) -> nil
;; summary: Ingest a bus event into transcript rows and TUI status side effects, including streaming coalescing and cache invalidation.
;; tags: tui ingest events transcript status
(fn append-event-inner [ev]
  (when (or (= ev.type :user)
            (= ev.type :steering-injected)
            (= ev.type :follow-up-injected))
    (set state.last-user-jump-index nil))
  ;; Anchor a backlog-reading viewport while content grows below; a tail-relative offset would drag it down.
  (let [was-scrolled? (> state.scroll-offset 0)
        before-max (if was-scrolled? (paint.max-scroll) 0)]
    (var invalidate? true)
  (if (= ev.type :llm-start)
      (do (set state.status-info.thinking? true)
          (set state.status-info.retrying? false)
          (set state.status-info.retry-attempt 0)
          (set state.status-info.retry-max-attempts 0)
          (set state.status-info.retry-delay-ms 0)
          (set state.status-info.retry-reason nil)
          ;; Turn-start stamps on the first llm-start of a turn; cleared on turn completion.
          (when (= (or state.status-info.turn-start 0) 0)
            (set state.status-info.turn-start (os.time))))

      (= ev.type :llm-end)
      (do (set state.status-info.thinking? false)
          (clear-hosted-tools!)
          (set state.status-info.retrying? false)
          (set state.status-info.retry-attempt 0)
          (set state.status-info.retry-max-attempts 0)
          (set state.status-info.retry-delay-ms 0)
          (set state.status-info.retry-reason nil)
          (when ev.usage
            (let [u ev.usage
                  s state.status-info]
              (set s.cum-input       (+ (or s.cum-input 0)       (or u.input 0)))
              (set s.cum-output      (+ (or s.cum-output 0)      (or u.output 0)))
              (set s.cum-cache-read  (+ (or s.cum-cache-read 0)  (or u.cache-read 0)))
              (set s.cum-cache-write (+ (or s.cum-cache-write 0) (or u.cache-write 0)))
              (set s.last-input      (or u.input s.last-input)))))

      (= ev.type :provider-retry)
      (let [s state.status-info]
        (clear-hosted-tools!)
        (set s.retrying? true)
        (set s.retry-attempt (or ev.attempt 0))
        (set s.retry-max-attempts (or ev.max-attempts 0))
        (set s.retry-delay-ms (or ev.delay-ms 0))
        (set s.retry-reason ev.reason))

      (= ev.type :hosted-tool)
      (if (= ev.phase :start)
          (track-running-tool! (hosted-tool-key ev) (hosted-tool-label ev :running))
          (= ev.phase :end)
          (do (untrack-running-tool! (hosted-tool-key ev))
              (table.insert state.transcript (hosted-tool-row ev)))
          (set invalidate? false))

      (= ev.type :tool-call)
      (do
          (set ev.short (transcript.tool-call-short ev.name ev.arguments))
          (set ev.args-pretty (transcript.args->string ev.arguments))
          (track-running-tool! ev.id (or ev.short (tostring ev.name)))
          (table.insert state.transcript ev))

      (= ev.type :tool-result)
      (let [result-id (or ev.id ev.tool-call-id)]
        (when (= ev.is-error? nil)
          (set ev.is-error? (not (not (?. ev :result :is-error?)))))
        (untrack-running-tool! result-id)
        (let [text (transcript.content->text (?. ev :result :content))
              tc (transcript.lookup-tool-call result-id)]
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
          (clear-running-tools!)
          (set state.status-info.cancelling? false)
          (set state.status-info.turn-start 0)
          (table.insert state.transcript ev))

      (= ev.type :assistant-text)
      (do (when (not= ev.final? false)
            (set state.status-info.thinking? false)
            (set state.status-info.retrying? false)
            (clear-running-tools!)
            (set state.status-info.turn-start 0))
          (table.insert state.transcript ev))

      (= ev.type :assistant-thinking)
      (do (when ev.final?
            (set state.status-info.thinking? false)
            (set state.status-info.retrying? false)
            (clear-running-tools!)
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
            (clear-running-tools!)
            (set state.status-info.turn-start 0)))

      (= ev.type :error)
      (do (set state.status-info.thinking? false)
          (set state.status-info.retrying? false)
          (clear-running-tools!)
          (set state.status-info.turn-start 0)
          (table.insert state.transcript ev))

      (= ev.type :extension-loaded)
      ;; Normalize loader diagnostics at append time so they survive renderer reloads.
      (table.insert state.transcript
                    {:type :info
                     :text (.. "extension-loaded: "
                               (tostring (or ev.name "")))})

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

(fn M.append-event [ev ?opts]
  "Ingest EV. With :transcript-only?, status side effects land in the
   caller-owned :status-info table (a throwaway one when absent) instead of
   the main session's status model."
  (if (?. ?opts :transcript-only?)
      (let [saved state.status-info]
        (set state.status-info (or (?. ?opts :status-info) {}))
        (let [(ok? err) (xpcall #(append-event-inner ev) debug.traceback)]
          (set state.status-info saved)
          (when (not ok?) (error err))))
      (append-event-inner ev)))

M
