;; Public HTTP transport API used by providers.
;;
;; All HTTP traffic in fen flows through `request`, which dispatches to
;; the backend selected by `fen.util.http.backend`. The default backend
;; is lua-curl (`fen.util.http.backends.curl`); tests stub the backend by
;; pre-loading `package.loaded["fen.util.http.backend"]`. Provider code
;; must not require `cURL` directly — that constraint is what lets us
;; embed a different transport for single-file builds (#66) or swap the
;; binding for WASM.

(local backend (require :fen.util.http.backend))

(fn request [opts]
  "Perform an HTTP request.

   opts:
     :method            \"POST\" or \"GET\"  (default \"GET\")
     :url               request URL          (required)
     :headers           {name value} table   (optional)
     :body              pre-encoded string    (optional; required for POST)
     :timeout-ms        overall timeout       (optional, default 600000)
     :connect-timeout-ms connect timeout      (optional, default 30000)
     :on-chunk          (fn [bytes] ...)      (optional; streaming sink)
     :yield             (fn [] ...)           (optional; cooperative mode)

   Returns one of:
     {:status N :body string}     transport success (any HTTP status)
     {:error string}              transport failure (DNS/TLS/timeout/etc.)

   When :on-chunk is provided, raw response bytes flow through it as they
   arrive AND are accumulated into :body, so the caller can use the body
   for error reporting on non-2xx status without giving up streaming.
   When :yield is provided, the request is driven cooperatively (no VM
   block); the yield function is called between transport ticks."
  (backend.request opts))

{: request}
