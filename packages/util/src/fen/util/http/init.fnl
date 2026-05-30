;; Public HTTP transport API used by providers.
;;
;; All HTTP traffic in fen flows through `request`, which dispatches to
;; the backend selected by `fen.util.http.backend`. The default backend
;; is the project-owned libcurl C module shipped as `fen_http.so`
;; (`fen.util.http.backends.native`); tests stub the backend by
;; pre-loading `package.loaded["fen.util.http.backend"]`. Provider code
;; must not require the transport directly — that constraint is what lets
;; us swap libcurl for a smaller TLS/HTTP stack in single-file builds
;; (#66) or for a different binding under WASM.

(local backend (require :fen.util.http.backend))

;; @doc fen.util.http.request
;; kind: function
;; signature: (request opts) -> {:status :body :headers}|{:error}
;; summary: Perform an HTTP request through the selected backend, supporting streaming chunks and cooperative yielding.
;; tags: util http providers
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

   When :on-chunk is provided, raw response bytes flow through it as they
   arrive AND (unless :accumulate-body? is false) are accumulated into :body,
   so the caller can use the body for error reporting on non-2xx status
   without giving up streaming. With :accumulate-body? false only a bounded
   head is retained for error diagnostics.
   When :yield is provided, the request is driven cooperatively (no VM
   block); the yield function is called between transport ticks."
  (backend.request opts))

{: request}
