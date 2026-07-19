;; Shared authenticated model-catalog probe for OpenAI-compatible providers.

(local http (require :fen.util.http))
(local json (require :fen.util.json))

(local DEFAULT-BASE-URL "https://api.openai.com/v1")

(fn strip-suffix [s suffix]
  (if (= (string.sub s (- (length s) (length suffix) -1)) suffix)
      (string.sub s 1 (- (length s) (length suffix)))
      s))

(fn models-url [base-url]
  (let [root (-> (or base-url DEFAULT-BASE-URL)
                 (strip-suffix "/chat/completions")
                 (strip-suffix "/responses"))]
    (if (= (string.sub root -1) "/")
        (.. root "models")
        (.. root "/models"))))

(fn request-headers [api-key]
  (let [headers {:accept "application/json"}]
    (when (and api-key (not= api-key ""))
      (set headers.authorization (.. "Bearer " api-key)))
    headers))

(fn list-models [opts]
  (let [opts (or opts {})
        resp (http.request {:method :GET
                            :url (models-url opts.base-url)
                            :headers (request-headers (or opts.api-key opts.api_key))
                            :timeout-ms (or opts.timeout-ms 30000)
                            :connect-timeout-ms (or opts.connect-timeout-ms 10000)
                            :yield opts.yield})]
    (when resp.error
      (error {:reason :request-failed}))
    (when (or (< resp.status 200) (>= resp.status 300))
      (error {:reason (if (or (= resp.status 401) (= resp.status 403))
                          :authentication-failed
                          :request-failed)}))
    (let [body (json.decode (or resp.body ""))
          out []]
      (each [_ item (ipairs (or body.data []))]
        (when (and (= (type item) :table) item.id)
          (table.insert out {:id item.id})))
      out)))

{: list-models :models-url models-url}
