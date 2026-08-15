;; All HTTP flows through `request`; providers must not require the transport directly.

(local backend (require :fen.util.http.backend))

;; Timeout defaults applied once here so backends see always-present fields (#469); 0 disables the stall watchdog and `or` preserves it (0 is truthy in Lua).
(local default-timeout-ms 600000)
(local default-connect-timeout-ms 30000)
(local default-idle-timeout-ms 60000)

;; Optional backend :capabilities; only :blocking? today; absent means blocking allowed.
(fn blocking-supported? []
  (not (and backend.capabilities (= backend.capabilities.blocking? false))))

(fn request [opts]
  "Perform an HTTP request.

   opts:
     :method            \"POST\" or \"GET\"  (default \"GET\")
     :url               request URL          (required)
     :headers           {name value} table   (optional)
     :body              pre-encoded string    (optional; required for POST)
     :timeout-ms        overall timeout       (optional, default 600000)
     :connect-timeout-ms connect timeout      (optional, default 30000)
     :idle-timeout-ms   stall watchdog        (optional, default 60000;
                                               abort if throughput stays near
                                               zero this long; 0 disables.
                                               FEN_HTTP_IDLE_TIMEOUT_MS env
                                               overrides. Surfaces as a curl
                                               timeout the retry layer retries.)
     :on-chunk          (fn [bytes] ...)      (optional; streaming sink)
     :accumulate-body?  bool                  (optional, default true; set
                                               false on streaming requests to
                                               skip buffering the full body. A
                                               bounded head is still kept for
                                               error diagnostics.)
     :yield             (fn [] ...)           (optional; cooperative mode)

   Returns one of:
     {:status N :body string :headers table}
                                  transport success (any HTTP status)
     {:error string :curl-code number?}
                                  transport failure (DNS/TLS/timeout/etc.);
                                  native libcurl failures include CURLE code
     {:error string :capability \"blocking\"}
                                  the selected backend declared
                                  {:blocking? false} but the caller passed no
                                  :yield, so no cooperative driver exists
                                  (#471). Fails fast before dispatch; the
                                  :capability field names the unmet capability.

   When :on-chunk is provided, raw response bytes flow through it as they
   arrive AND (unless :accumulate-body? is false) are accumulated into :body,
   so the caller can use the body for error reporting on non-2xx status
   without giving up streaming. With :accumulate-body? false only a bounded
   head is retained for error diagnostics.
   When :yield is provided, the request is driven cooperatively (no VM
   block); the yield function is called between transport ticks."
  (if (and (not opts.yield) (not (blocking-supported?)))
      ;; Fail fast: a cooperative-only backend with no :yield cannot proceed (#471).
      {:error (.. "fen.util.http: backend transport cannot block; "
                  "pass :yield to drive the request cooperatively")
       :capability "blocking"}
      ;; Shallow-copy so the timeout defaults never mutate the caller's table.
      (let [merged (collect [k v (pairs opts)] k v)]
        (set merged.timeout-ms (or opts.timeout-ms default-timeout-ms))
        (set merged.connect-timeout-ms (or opts.connect-timeout-ms
                                           default-connect-timeout-ms))
        (set merged.idle-timeout-ms (or opts.idle-timeout-ms default-idle-timeout-ms))
        (backend.request merged))))

{: request}
