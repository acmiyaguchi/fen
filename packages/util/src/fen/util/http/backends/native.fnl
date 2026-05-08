;; Native libcurl backend for fen.util.http.
;;
;; Wraps the project-owned `fen_http` C module (packages/util/vendor/fen_http.c,
;; built into packages/util/dist/fen_http.so). The C side owns easy-handle
;; setup, header conversion, body wiring, perform-path selection (blocking
;; via curl_easy_perform, cooperative via curl_multi), status extraction,
;; response accumulation, and error stringification.
;;
;; Contract — `fen.util.http.request` opts use kebab-case
;; (`:timeout-ms`, `:connect-timeout-ms`, `:on-chunk`); the C entry point
;; expects snake_case (`timeout_ms`, `connect_timeout_ms`, `on_chunk`).
;; This file is the translation point.

(fn translate [opts]
  {:method opts.method
   :url opts.url
   :headers opts.headers
   :body opts.body
   :timeout_ms opts.timeout-ms
   :connect_timeout_ms opts.connect-timeout-ms
   :on_chunk opts.on-chunk
   :yield opts.yield})

;; @doc fen.util.http.backends.native.request
;; kind: function
;; signature: (request opts) -> {:status :body :headers}|{:error}
;; summary: Translate kebab-case HTTP options and dispatch to the project-owned fen_http libcurl binding.
;; tags: util http native
(fn request [opts]
  ;; Lazy require so loading a provider module under tests (where the
  ;; whole HTTP backend is stubbed) does not pull the C extension into
  ;; package.loaded.
  (let [fen-http (require :fen_http)]
    (fen-http.request (translate opts))))

{: request}
