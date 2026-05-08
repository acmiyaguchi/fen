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
     :on-chunk          (fn [bytes] ...)      (optional; streaming sink)
     :yield             (fn [] ...)           (optional; cooperative mode)

   Returns one of:
     {:status N :body string :headers table}
                                  transport success (any HTTP status)
     {:error string}              transport failure (DNS/TLS/timeout/etc.)

   When :on-chunk is provided, raw response bytes flow through it as they
   arrive AND are accumulated into :body, so the caller can use the body
   for error reporting on non-2xx status without giving up streaming.
   When :yield is provided, the request is driven cooperatively (no VM
   block); the yield function is called between transport ticks."
  (backend.request opts))

{: request}
