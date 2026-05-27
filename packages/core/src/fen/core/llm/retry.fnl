;; Retry helpers for provider HTTP calls.
;;
;; Conservative by design: retry only explicit transient transport/HTTP
;; failures, keep the loop below the agent message layer, and let callers pass
;; a cooperative yield function so cancellation can cut through backoff waits.

(local process (require :fen.util.process))

;; @doc fen.core.llm.retry.DEFAULT-MAX-ATTEMPTS
;; kind: data
;; signature: number
;; summary: Default maximum number of provider HTTP attempts, including the initial try and transient retries.
;; tags: llm retry defaults
(local DEFAULT-MAX-ATTEMPTS 4)

;; @doc fen.core.llm.retry.DEFAULT-BASE-DELAY-MS
;; kind: data
;; signature: number
;; summary: Default base delay in milliseconds used as the first exponential-backoff jitter cap.
;; tags: llm retry defaults
(local DEFAULT-BASE-DELAY-MS 1000)

;; @doc fen.core.llm.retry.DEFAULT-MAX-DELAY-MS
;; kind: data
;; signature: number
;; summary: Default maximum jitter cap in milliseconds for provider retry backoff delays.
;; tags: llm retry defaults
(local DEFAULT-MAX-DELAY-MS 30000)

(fn lowercase [s]
  (string.lower (tostring s)))

;; Stable libcurl CURLE_* codes that are safe to retry below the message
;; layer. The native backend exposes these as :curl-code on transport
;; failures; deliberately excluded examples include CURLE_COULDNT_RESOLVE_HOST
;; (6) and CURLE_PEER_FAILED_VERIFICATION (60), which are usually persistent
;; configuration/environment failures.
(local TRANSIENT-CURL-CODES
  {7 true    ; CURLE_COULDNT_CONNECT
   16 true   ; CURLE_HTTP2
   18 true   ; CURLE_PARTIAL_FILE
   28 true   ; CURLE_OPERATION_TIMEDOUT
   35 true   ; CURLE_SSL_CONNECT_ERROR
   52 true   ; CURLE_GOT_NOTHING
   55 true   ; CURLE_SEND_ERROR
   56 true   ; CURLE_RECV_ERROR
   92 true}) ; CURLE_HTTP2_STREAM

(fn transient-curl-code? [curl-code]
  (let [code (tonumber curl-code)]
    (if (and code (. TRANSIENT-CURL-CODES code)) true false)))

;; @doc fen.core.llm.retry.transient?
;; kind: function
;; signature: (transient? status err-message ?curl-code) -> boolean
;; summary: Return true for provider HTTP status or curl code that is safe to retry below the agent message layer.
;; tags: llm http retry
(fn transient? [status err-message ?curl-code]
  "True when a provider HTTP/transport failure is worth retrying."
  (if (or (= status 429)
          (and status (>= status 500) (< status 600))
          (and (not status) (transient-curl-code? ?curl-code)))
      true
      false))

(fn header [headers name]
  "Case-insensitive lookup in a simple response header table."
  (var out nil)
  (when headers
    (let [needle (lowercase name)]
      (each [k v (pairs headers)]
        (when (= (lowercase k) needle)
          (set out v)))))
  out)

(local MONTHS {:Jan 1 :Feb 2 :Mar 3 :Apr 4 :May 5 :Jun 6
               :Jul 7 :Aug 8 :Sep 9 :Oct 10 :Nov 11 :Dec 12})

(fn parse-http-date [s]
  ;; Parse the common IMF-fixdate form: "Wed, 21 Oct 2015 07:28:00 GMT".
  ;; Lua has os.time (local time) but no portable timegm; this is still useful
  ;; for the overwhelmingly common relative comparison, and falls back to
  ;; exponential backoff when the date shape is not recognized.
  (let [(day mon year hour min sec)
        (string.match (tostring (or s ""))
                      "^%a%a%a,%s+(%d%d?)%s+(%a%a%a)%s+(%d%d%d%d)%s+(%d%d):(%d%d):(%d%d)%s+GMT$")]
    (when (and day mon year hour min sec (. MONTHS mon))
      (let [target (os.time {:year (tonumber year)
                             :month (. MONTHS mon)
                             :day (tonumber day)
                             :hour (tonumber hour)
                             :min (tonumber min)
                             :sec (tonumber sec)})
            now (os.time)]
        (math.max 0 (math.floor (* 1000 (os.difftime target now))))))))

;; @doc fen.core.llm.retry.parse-retry-after
;; kind: function
;; signature: (parse-retry-after headers) -> number|nil
;; summary: Parse Retry-After or retry-after-ms response headers into a millisecond delay for provider backoff.
;; tags: llm http retry
(fn parse-retry-after [headers]
  "Return delay-ms from Retry-After/retry-after-ms headers, or nil."
  (let [ms (or (header headers :retry-after-ms)
               (header headers "retry-after-ms"))
        seconds (or (header headers :retry-after)
                    (header headers "retry-after"))]
    (if (and ms (tonumber ms))
        (math.max 0 (math.floor (tonumber ms)))
        (and seconds (tonumber seconds))
        (math.max 0 (math.floor (* (tonumber seconds) 1000)))
        seconds
        (parse-http-date seconds)
        nil)))

;; @doc fen.core.llm.retry.backoff-delay
;; kind: function
;; signature: (backoff-delay attempt base-ms max-ms) -> number
;; summary: Compute a full-jitter exponential backoff delay in milliseconds for the given failed attempt number.
;; tags: llm http retry
(fn backoff-delay [attempt base-ms max-ms]
  "Exponential backoff with full jitter.
   `attempt` is 1-indexed failed attempt number; after the first failure the
   cap is base-ms, after the second it is base-ms*2, etc."
  (let [base (or base-ms DEFAULT-BASE-DELAY-MS)
        max-delay (or max-ms DEFAULT-MAX-DELAY-MS)
        cap (math.min max-delay (* base (^ 2 (- attempt 1))))]
    (if (<= cap 0)
        0
        (math.random 0 (math.floor cap)))))

(fn reason [resp]
  (if resp.error
      (.. "curl: " (tostring resp.error))
      resp.status
      (.. "HTTP " (tostring resp.status))
      "unknown"))

(fn default-sleep-ms [delay-ms ?yield!]
  "Sleep without shelling out. In cooperative mode, yield until the deadline
   and let the presenter loop provide the actual pacing between resumes so
   retry backoff does not freeze the TUI in 100ms chunks."
  (let [delay (math.max 0 (or delay-ms 0))]
    (if ?yield!
        (do
          (?yield!)
          (let [deadline (+ (process.monotonic-ms) delay)]
            (while (< (process.monotonic-ms) deadline)
              (?yield!))))
        (> delay 0)
        (process.sleep-ms delay))))

(fn normalize-opts [opts]
  (let [o (or opts {})]
    {:max-attempts (or o.max-attempts DEFAULT-MAX-ATTEMPTS)
     :base-delay-ms (or o.base-delay-ms DEFAULT-BASE-DELAY-MS)
     :max-delay-ms (or o.max-delay-ms DEFAULT-MAX-DELAY-MS)
     :sleep (or o.sleep default-sleep-ms)
     :on-retry o.on-retry}))

(fn mark-incomplete-stream [resp incomplete?]
  "Tag a clean 2xx streaming response that ended without a terminal event so
   with-retry treats it like a transient transport failure. The caller owns the
   provider stream state and passes the incompleteness decision. Returns resp so
   it can wrap the make-request tail call."
  (when (and incomplete? resp (not resp.error)
             resp.status (<= 200 resp.status) (< resp.status 300))
    (set resp.retry-incomplete-stream true))
  resp)

(fn retryable-response? [resp]
  (and resp (or (. resp :retry-incomplete-stream)
                (transient? resp.status resp.error (. resp :curl-code)))))

;; @doc fen.core.llm.retry.options
;; kind: function
;; signature: (options provider ?opts ?on-event) -> table
;; summary: Build with-retry options from provider request opts, honoring AGENT_FENNEL_RETRY=0 and emitting tagged :provider-retry events.
;; tags: llm http retry
(fn options [provider ?opts ?on-event]
  "Build with-retry options shared by provider adapters.
   Honors AGENT_FENNEL_RETRY=0 to disable retries and forwards retry
   backoff knobs from `?opts`; `on-retry` emits a :provider-retry event
   tagged with `provider` when `?on-event` is supplied."
  (let [opts (or ?opts {})
        env-retry (os.getenv :AGENT_FENNEL_RETRY)
        max-attempts (if (= env-retry "0")
                         1
                         (or opts.retry-max-attempts DEFAULT-MAX-ATTEMPTS))]
    {:max-attempts max-attempts
     :base-delay-ms (or opts.retry-base-delay-ms DEFAULT-BASE-DELAY-MS)
     :max-delay-ms (or opts.retry-max-delay-ms DEFAULT-MAX-DELAY-MS)
     :on-retry (fn [ev]
                 (when ?on-event
                   (?on-event {:type :provider-retry
                               :provider provider
                               :attempt ev.attempt
                               :max-attempts ev.max-attempts
                               :delay-ms ev.delay-ms
                               :reason ev.reason})))}))

;; @doc fen.core.llm.retry.with-retry
;; kind: function
;; signature: (with-retry opts make-request ?yield!) -> response
;; summary: Run a provider request with bounded retry, Retry-After support, jittered backoff, and cooperative cancellation yields.
;; tags: llm http retry
(fn with-retry [opts make-request ?yield!]
  "Run make-request with conservative retry on transient HTTP/transport errors.

   opts: {:max-attempts :base-delay-ms :max-delay-ms :sleep :on-retry}
   make-request: (attempt) -> {:status :body :headers} | {:error string}
   ?yield!: optional cancellation-aware yield function.

   Returns the final response, whether success, terminal failure, or exhausted
   transient failure."
  (let [o (normalize-opts opts)
        max-attempts (math.max 1 (or o.max-attempts 1))]
    (var attempt 0)
    (var final nil)
    (while (and (= final nil) (< attempt max-attempts))
      (set attempt (+ attempt 1))
      (let [resp (make-request attempt)]
        (if (and (< attempt max-attempts) (retryable-response? resp))
            (let [delay (or (parse-retry-after resp.headers)
                            (backoff-delay attempt o.base-delay-ms o.max-delay-ms))]
              (when o.on-retry
                (o.on-retry {:attempt (+ attempt 1)
                             :failed-attempt attempt
                             :max-attempts max-attempts
                             :delay-ms delay
                             :reason (reason resp)
                             :response resp}))
              (o.sleep delay ?yield!))
            (set final resp))))
    final))

{:DEFAULT-MAX-ATTEMPTS DEFAULT-MAX-ATTEMPTS
 :DEFAULT-BASE-DELAY-MS DEFAULT-BASE-DELAY-MS
 :DEFAULT-MAX-DELAY-MS DEFAULT-MAX-DELAY-MS
 :transient? transient?
 :mark-incomplete-stream mark-incomplete-stream
 :options options
 :parse-retry-after parse-retry-after
 :backoff-delay backoff-delay
 :with-retry with-retry}
