;; Shared streaming-provider transport skeleton.
;;
;; Provider adapters keep their wire conversion and event reducers locally, but
;; the retry loop, SSE/parser plumbing, HTTP opts shape, and terminal stream
;; error handling live here.

(local types (require :fen.core.types))
(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local http (require :fen.util.http))
(local sse (require :fen.util.sse))
(local retry (require :fen.extensions.provider_shared.retry))

(local M {})

(fn call [f ...]
  (if (= (type f) :function)
      (f ...)
      f))

(fn default-process-frame [state frame emit parser-error config]
  (when (not parser-error.message)
    (let [data (or frame.data "")]
      (if (and config.done-sentinel (= data config.done-sentinel))
          (set state.saw-terminal? true)
          (not= data "")
          (let [(ok? decoded) (pcall json.decode data)]
            (if ok?
                (config.process-event state decoded emit)
                (set parser-error.message decoded)))))))

;; @doc fen.extensions.provider_shared.streaming.make-stream-pipeline
;; kind: function
;; signature: (make-stream-pipeline config) -> state, parser, parser-error
;; summary: Build shared SSE parser plumbing for provider streaming reducers.
;; tags: provider streaming shared
(fn M.make-stream-pipeline [config]
  "Build a fresh (state parser parser-error) tuple.
   config: {:model :new-state :process-event :on-event :done-sentinel
            :process-frame}
   `process-event` owns provider-specific decoded event folding; adapters may
   override frame handling with `process-frame`."
  (let [state (config.new-state config.model)
        parser-error {:message nil}
        process-frame (or config.process-frame default-process-frame)
        parser (sse.new-parser
                 (fn [frame]
                   (process-frame state frame config.on-event parser-error config)))]
    (values state parser parser-error)))

;; @doc fen.extensions.provider_shared.streaming.build-request-opts
;; kind: function
;; signature: (build-request-opts spec model context options ?on-chunk) -> table
;; summary: Assemble the common fen.util.http POST opts shape for provider calls.
;; tags: provider streaming http shared
(fn M.build-request-opts [spec model context options ?on-chunk]
  "Assemble a fen.util.http opts table for a provider POST.
   spec callbacks: :url, :headers, :build-body. The body callback receives
   (model context opts streaming?) and should set provider-specific stream
   fields when streaming? is true."
  (let [opts (or options {})
        streaming? (not= ?on-chunk nil)
        body (spec.build-body model context opts streaming?)]
    {:method :POST
     :url (call spec.url opts streaming?)
     :headers (spec.headers opts streaming?)
     :body (json.encode body)
     :timeout-ms (or opts.timeout-ms spec.default-timeout-ms)
     :connect-timeout-ms (or opts.connect-timeout-ms spec.default-connect-timeout-ms)
     :idle-timeout-ms opts.idle-timeout-ms
     ;; Streaming success builds the result from parsed stream state, never
     ;; resp.body. Non-streaming response parsers need the full body.
     :accumulate-body? (not streaming?)
     :on-chunk ?on-chunk}))

;; @doc fen.extensions.provider_shared.streaming.finalize-stream-state
;; kind: function
;; signature: (finalize-stream-state config) -> AssistantMessage
;; summary: Convert reducer state into a canonical assistant message and emit the terminal done/error event.
;; tags: provider streaming finalize shared
(fn M.finalize-stream-state [config]
  "Shared reducer-state finalization for streaming providers.
   config: {:api :provider :state :emit :finish}. `finish`, when present,
   closes provider-specific in-progress blocks before the canonical assistant
   message is built."
  (let [state config.state
        emit config.emit]
    (when config.finish
      (config.finish state emit))
    (when (and (= state.stop-reason :stop)
               (> (length (types.assistant-tool-calls {:content state.content})) 0))
      (set state.stop-reason :tool-use))
    (let [asst (types.assistant-message
                 {:api config.api :provider config.provider :model state.model
                  :content state.content
                  :usage state.usage
                  :stop-reason state.stop-reason
                  :error-message state.error-message})]
      (when emit
        (emit (if (= asst.stop-reason :error)
                  {:type :error :message asst}
                  {:type :done :message asst})))
      asst)))

;; @doc fen.extensions.provider_shared.streaming.finalize-stream
;; kind: function
;; signature: (finalize-stream config) -> AssistantMessage
;; summary: Convert transport, parser, HTTP, incomplete-stream, or reducer output into a terminal assistant message.
;; tags: provider streaming finalize shared
(fn M.finalize-stream [config]
  "Shared post-request handling for streaming pipelines.
   config: {:api :provider :model :state :parser :parser-error :resp :on-event
            :finalize-state :incomplete-log-prefix}"
  (let [api config.api
        provider config.provider
        model config.model
        state config.state
        parser config.parser
        parser-error config.parser-error
        resp config.resp
        on-event config.on-event]
    (when (and resp (not resp.error))
      (parser.finish))
    (if (and resp resp.error)
        (let [asst (types.assistant-error api provider model resp.error)]
          (when on-event (on-event {:type :error :message asst}))
          asst)
        (and parser-error (not= parser-error.message nil))
        (let [asst (types.assistant-error api provider model parser-error.message)]
          (when on-event (on-event {:type :error :message asst}))
          asst)
        (or (not resp) (< resp.status 200) (>= resp.status 300))
        (let [body (or (and resp resp.body) "")
              status (or (and resp resp.status) "?")
              asst (types.assistant-error api provider model
                                          (.. "HTTP " status ": " body))]
          (log.error (.. "http " status ": " body))
          (when on-event (on-event {:type :error :message asst}))
          asst)
        (not state.saw-terminal?)
        (let [asst (types.assistant-error api provider model types.INCOMPLETE-STREAM-MSG)]
          (log.error (.. (or config.incomplete-log-prefix (tostring provider))
                         ": " types.INCOMPLETE-STREAM-MSG))
          (when on-event (on-event {:type :error :message asst}))
          asst)
        (config.finalize-state state on-event))))

;; @doc fen.extensions.provider_shared.streaming.complete-streaming
;; kind: function
;; signature: (complete-streaming config) -> AssistantMessage
;; summary: Run the shared provider retry/HTTP loop for adapters that always use an SSE stream.
;; tags: provider streaming complete shared
(fn M.complete-streaming [config]
  "Shared provider entry loop for adapters that always stream, even when the
   caller did not request delta events."
  (let [model config.model
        context config.context
        options config.options
        on-event config.on-event
        yield-fn config.yield-fn
        latest {:state nil :parser nil :parser-error nil :request-opts nil}]
    (when on-event (on-event {:type :start}))
    (let [resp (retry.with-retry
                 (retry.options config.provider options on-event)
                 (fn [_attempt]
                   (let [(state parser parser-error)
                         (config.make-stream-pipeline model on-event)
                         req-opts (config.build-request-opts
                                    model context options
                                    (fn [chunk] (parser.feed chunk)))]
                     (set latest.state state)
                     (set latest.parser parser)
                     (set latest.parser-error parser-error)
                     (set latest.request-opts req-opts)
                     (set req-opts.yield yield-fn)
                     (let [resp (http.request req-opts)]
                       (when (not resp.error) (parser.finish))
                       (retry.mark-incomplete-stream
                         resp
                         (and (not parser-error.message)
                              (not state.saw-terminal?))))))
                 yield-fn)]
      (config.finalize-stream latest.state latest.parser latest.parser-error
                              model resp on-event latest.request-opts))))

;; @doc fen.extensions.provider_shared.streaming.complete
;; kind: function
;; signature: (complete config) -> AssistantMessage
;; summary: Run the shared provider retry/HTTP loop for streaming or non-streaming requests.
;; tags: provider streaming complete shared
(fn M.complete [config]
  "Shared provider entry loop.
   config callbacks preserve adapter-local public signatures:
   :build-request-opts, :make-stream-pipeline, :finalize-stream,
   :response->assistant."
  (let [model config.model
        context config.context
        options config.options
        on-event config.on-event
        yield-fn config.yield-fn]
    (if on-event
        (let [latest {:state nil :parser nil :parser-error nil}]
          (on-event {:type :start})
          (let [resp (retry.with-retry
                       (retry.options config.provider options on-event)
                       (fn [_attempt]
                         (let [(state parser parser-error)
                               (config.make-stream-pipeline model on-event)
                               req-opts (config.build-request-opts
                                          model context options
                                          (fn [chunk] (parser.feed chunk)))]
                           (set latest.state state)
                           (set latest.parser parser)
                           (set latest.parser-error parser-error)
                           (set req-opts.yield yield-fn)
                           (let [resp (http.request req-opts)]
                             ;; Flush a terminal event the parser buffered (one
                             ;; whose trailing blank line never arrived) before
                             ;; judging completeness, so a complete-but-
                             ;; unterminated stream is not needlessly retried.
                             ;; finish is idempotent; finalize-stream calls it again.
                             (when (not resp.error) (parser.finish))
                             (retry.mark-incomplete-stream
                               resp
                               (and (not parser-error.message)
                                    (not state.saw-terminal?))))))
                       yield-fn)]
            (config.finalize-stream latest.state latest.parser latest.parser-error
                                    model resp on-event)))
        (let [resp (retry.with-retry
                     (retry.options config.provider options on-event)
                     (fn [_attempt]
                       (let [req-opts (config.build-request-opts model context options nil)]
                         (set req-opts.yield yield-fn)
                         (http.request req-opts)))
                     yield-fn)]
          (config.response->assistant model resp)))))

M
