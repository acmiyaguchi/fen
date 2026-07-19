(local catalog (require :fen.extensions.provider_openai.openai_model_catalog))
(local http (require :fen.util.http))
(local json (require :fen.util.json))

(describe "providers.openai_model_catalog"
  (fn []
    (var old-request nil)

    (before_each (fn [] (set old-request http.request)))
    (after_each (fn [] (set http.request old-request)))

    (it "checks the models endpoint without exposing the credential in its result"
      (fn []
        (var captured nil)
        (set http.request
             (fn [opts]
               (set captured opts)
               {:status 200 :headers {}
                :body (json.encode {:data [{:id "gpt-test"}]})}))
        (let [models (catalog.list-models {:api-key "secret"
                                           :base-url "https://example.test/v1/responses"})]
          (assert.are.equal "https://example.test/v1/models" captured.url)
          (assert.are.equal "Bearer secret" captured.headers.authorization)
          (assert.are.equal "gpt-test" (. models 1 :id)))))

    (it "preserves authless OpenAI-compatible probes"
      (fn []
        (var captured nil)
        (set http.request
             (fn [opts]
               (set captured opts)
               {:status 200 :headers {} :body "{\"data\":[]}"}))
        (catalog.list-models {:base-url "http://localhost:11434/v1"})
        (assert.is_nil captured.headers.authorization)))

    (it "reduces HTTP failures to structured secret-free reasons"
      (fn []
        (set http.request
             (fn [_]
               {:status 401 :headers {} :body "token=secret"}))
        (let [(ok? err) (pcall catalog.list-models {:api-key "secret"})]
          (assert.is_false ok?)
          (assert.are.equal :authentication-failed err.reason)
          (assert.is_nil err.body)
          (assert.is_nil (string.find (tostring err) "secret" 1 true)))
        (set http.request
             (fn [_]
               {:status 503 :headers {} :body "upstream details"}))
        (let [(ok? err) (pcall catalog.list-models {})]
          (assert.is_false ok?)
          (assert.are.equal :request-failed err.reason))))))
