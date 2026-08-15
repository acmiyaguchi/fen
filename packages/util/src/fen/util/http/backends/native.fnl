;; libcurl backend over fen_http; translates kebab-case request opts to the C module's snake_case.

(fn translate [opts]
  {:method opts.method
   :url opts.url
   :headers opts.headers
   :body opts.body
   ;; Timeout fields always present: fen.util.http.request fills defaults so backends stay policy-free (#469).
   :timeout_ms opts.timeout-ms
   :connect_timeout_ms opts.connect-timeout-ms
   :idle_timeout_ms opts.idle-timeout-ms
   ;; nil -> C defaults to true; streaming callers pass false to skip accumulating the body.
   :accumulate_body opts.accumulate-body?
   :on_chunk opts.on-chunk
   :yield opts.yield})

(fn translate-response [resp]
  (when (and resp resp.curl_code)
    (set resp.curl-code resp.curl_code)
    (tset resp :curl_code nil))
  resp)

;; @doc fen.util.http.backends.native.request
;; kind: function
;; signature: (request opts) -> {:status :body :headers}|{:error :curl-code?}
;; summary: Translate kebab-case HTTP options/results and dispatch to the project-owned fen_http libcurl binding.
;; tags: util http native
(fn request [opts]
  ;; Lazy require so stubbed tests never pull the C extension into package.loaded.
  (let [fen-http (require :fen_http)]
    (translate-response (fen-http.request (translate opts)))))

;; Declares {:blocking? true} (#471); cooperative-only backends declare false and require :yield.
(local capabilities {:blocking? true})

{: request : capabilities}
