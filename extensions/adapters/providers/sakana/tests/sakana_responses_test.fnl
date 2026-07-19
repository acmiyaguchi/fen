;; Tests for the Sakana AI provider adapter.
;;
;; The wire conversion and SSE reducer are the shared OpenAI Responses code,
;; exercised in the openai provider tests. These tests cover only what is
;; Sakana-specific: endpoint URL, Bearer auth headers, reasoning-effort
;; clamping, option merging, and the registered model list / default.

(local sakana (require :fen.extensions.provider_sakana.sakana_responses))
(local init (require :fen.extensions.provider_sakana))
(local json (require :fen.util.json))
(local http (require :fen.util.http))

(describe "providers.sakana_responses.build-url"
  (fn []
    (it "appends /responses to a v1 base URL"
      (fn []
        (assert.are.equal "https://api.sakana.ai/v1/responses"
                          (sakana.build-url "https://api.sakana.ai/v1"))))

    (it "preserves an already-qualified responses URL"
      (fn []
        (assert.are.equal "https://api.sakana.ai/v1/responses"
                          (sakana.build-url "https://api.sakana.ai/v1/responses"))))

    (it "uses the provider default base URL"
      (fn []
        (assert.are.equal "https://api.sakana.ai/v1" sakana.default-base-url)))))

(describe "providers.sakana_responses.model catalog"
  (fn []
    (it "builds the Sakana models URL"
      (fn []
        (assert.are.equal "https://api.sakana.ai/v1/models"
                          (sakana.build-models-url "https://api.sakana.ai/v1"))
        (assert.are.equal "https://api.sakana.ai/v1/models"
                          (sakana.build-models-url "https://api.sakana.ai/v1/responses"))))

    (it "parses OpenAI-compatible data[] model ids"
      (fn []
        (let [models (sakana.parse-models {:data [{:id "fugu-ultra"} {:id "fugu"}]})]
          (assert.are.equal 2 (length models))
          (assert.are.equal "fugu-ultra" (. models 1 :id))
          (assert.are.equal "fugu" (. models 2 :id)))))

    (it "fetches the authenticated catalog"
      (fn []
        (let [old-request http.request
              captured {}]
          (set http.request
               (fn [opts]
                 (tset captured :opts opts)
                 {:status 200
                  :headers {}
                  :body (json.encode {:data [{:id "fugu-ultra"}]})}))
          (let [models (sakana.list-models {:api-key "sk-test"})]
            (set http.request old-request)
            (assert.are.equal :GET captured.opts.method)
            (assert.are.equal "https://api.sakana.ai/v1/models" captured.opts.url)
            (assert.are.equal "Bearer sk-test" captured.opts.headers.authorization)
            (assert.are.equal "fugu-ultra" (. models 1 :id)))))

    (it "returns structured secret-free catalog failure reasons"
      (fn []
        (let [old-request http.request]
          (set http.request (fn [_] {:status 401 :headers {} :body "token=sk-secret"}))
          (let [(ok? err) (pcall sakana.list-models {:api-key "sk-secret"})]
            (assert.is_false ok?)
            (assert.are.equal :authentication-failed err.reason)
            (assert.is_nil err.body)
            (assert.is_nil (string.find (tostring err) "sk-secret" 1 true)))
          (set http.request (fn [_] {:status 403 :headers {} :body "access denied"}))
          (let [(ok? err) (pcall sakana.list-models {})]
            (assert.is_false ok?)
            (assert.are.equal :authentication-failed err.reason))
          (set http.request (fn [_] {:status 503 :headers {} :body "upstream details"}))
          (let [(ok? err) (pcall sakana.list-models {})]
            (assert.is_false ok?)
            (assert.are.equal :request-failed err.reason))
          (set http.request (fn [_] {:error "transport secret"}))
          (let [(ok? err) (pcall sakana.list-models {})]
            (set http.request old-request)
            (assert.is_false ok?)
            (assert.are.equal :request-failed err.reason)
            (assert.is_nil (string.find (tostring err) "secret" 1 true))))))))

(describe "providers.sakana_responses.clamp-reasoning-effort"
  (fn []
    (it "maps xhigh and its max alias to xhigh"
      (fn []
        (assert.are.equal :xhigh (sakana.clamp-reasoning-effort :xhigh))
        (assert.are.equal :xhigh (sakana.clamp-reasoning-effort :max))))

    (it "maps every other non-off level up to high"
      (fn []
        (assert.are.equal :high (sakana.clamp-reasoning-effort :minimal))
        (assert.are.equal :high (sakana.clamp-reasoning-effort :low))
        (assert.are.equal :high (sakana.clamp-reasoning-effort :medium))
        (assert.are.equal :high (sakana.clamp-reasoning-effort :high))))

    (it "returns nil for nil/empty/off so reasoning is omitted"
      (fn []
        (assert.is_nil (sakana.clamp-reasoning-effort nil))
        (assert.is_nil (sakana.clamp-reasoning-effort ""))
        (assert.is_nil (sakana.clamp-reasoning-effort :off))))))

(describe "providers.sakana_responses.request-headers"
  (fn []
    (it "sets an Authorization Bearer line when an API key is present"
      (fn []
        (let [h (sakana.request-headers "sk-sakana-abc")]
          (assert.are.equal "Bearer sk-sakana-abc" h.authorization)
          (assert.are.equal "text/event-stream" h.accept)
          (assert.are.equal "application/json" h.content-type))))

    (it "omits the Authorization line for nil/empty keys"
      (fn []
        (assert.is_nil (. (sakana.request-headers nil) :authorization))
        (assert.is_nil (. (sakana.request-headers "") :authorization))))))

(describe "providers.sakana_responses.merge-options"
  (fn []
    (it "clamps a low reasoning-effort to high and defaults the include"
      (fn []
        (let [out (sakana.merge-options {:reasoning-effort :low})]
          (assert.are.equal :high out.reasoning-effort)
          (assert.are.equal 1 (length out.include))
          (assert.are.equal "reasoning.encrypted_content" (. out.include 1)))))

    (it "keeps xhigh, preserves caller includes, and adds encrypted reasoning"
      (fn []
        (let [out (sakana.merge-options {:reasoning-effort :xhigh
                                         :include ["custom.include"]})]
          (assert.are.equal :xhigh out.reasoning-effort)
          (assert.are.equal 2 (length out.include))
          (assert.are.equal "custom.include" (. out.include 1))
          (assert.are.equal "reasoning.encrypted_content" (. out.include 2)))))

    (it "does not duplicate encrypted reasoning when the caller already includes it"
      (fn []
        (let [out (sakana.merge-options {:reasoning-effort :high
                                         :include ["reasoning.encrypted_content"]})]
          (assert.are.equal 1 (length out.include))
          (assert.are.equal "reasoning.encrypted_content" (. out.include 1)))))

    (it "drops reasoning-effort and does not add an include for off"
      (fn []
        (let [out (sakana.merge-options {:reasoning-effort :off})]
          (assert.is_nil out.reasoning-effort)
          (assert.is_nil out.include))))

    (it "does not mutate the caller's options table or include list"
      (fn []
        (let [caller {:reasoning-effort :medium :include ["custom.include"]}
              _ (sakana.merge-options caller)]
          (assert.are.equal :medium caller.reasoning-effort)
          (assert.are.equal 1 (length caller.include))
          (assert.are.equal "custom.include" (. caller.include 1)))))

    (it "passes through unrelated options"
      (fn []
        (let [out (sakana.merge-options {:api-key "k" :base-url "u"})]
          (assert.are.equal "k" out.api-key)
          (assert.are.equal "u" out.base-url))))))

(describe "providers.sakana provider identity"
  (fn []
    (it "emits canonical assistant messages as provider sakana"
      (fn []
        (assert.are.equal :sakana sakana.provider)
        (assert.are.equal :openai-responses sakana.api)))))

(describe "providers.sakana registration"
  (fn []
    (it "registers a provider spec with the Fugu models and default"
      (fn []
        (let [captured {}]
          (init.register
            {:register (fn [kind spec]
                         (set captured.kind kind)
                         (set captured.spec spec))})
          (assert.are.equal :provider captured.kind)
          (assert.are.equal :sakana captured.spec.name)
          (assert.are.equal :fugu-ultra captured.spec.default-model)
          (assert.are.equal :SAKANA_API_KEY captured.spec.api-key-var)
          (assert.are.equal :openai-responses captured.spec.api)
          (assert.is_function captured.spec.complete)
          (assert.is_function captured.spec.list-models)
          (let [ids {}]
            (each [_ m (ipairs captured.spec.models)]
              (tset ids m.id true))
            (assert.is_true (. ids :fugu))
            (assert.is_true (. ids :fugu-ultra))
            (assert.is_true (. ids :fugu-ultra-20260615)))))))))
