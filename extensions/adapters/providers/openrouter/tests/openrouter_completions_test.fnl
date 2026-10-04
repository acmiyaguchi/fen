(local openrouter
       (require :fen.extensions.provider_openrouter.openrouter_completions))

(local init (require :fen.extensions.provider_openrouter))
(local types (require :fen.core.types))
(local json (require :fen.util.json))
(local http (require :fen.util.http))
(local h (require :fen.testing))
(local register (require :fen.core.extensions.register))
(local test-api (require :fen.core.extensions.test_api))
(local thinking (require :fen.core.thinking))

(local TOOLS [{:name "ls" :description "list" :parameters {:type :object}}])

(fn request-body [model context options]
  (json.decode (. (openrouter.build-request-opts model context (or options {})
                                                 nil) :body)))

(fn sse [...]
  "Encode tables as SSE data frames, then the [DONE] sentinel."
  (let [out []]
    (each [_ chunk (ipairs [...])]
      (table.insert out (.. "data: " (json.encode chunk) "\n\n")))
    (table.insert out "data: [DONE]\n\n")
    (table.concat out)))

(fn with-stream [payload f]
  "Run f while http.request streams payload; returns f's results and the
   captured request opts."
  (let [old-request http.request
        captured {}]
    (set http.request (fn [opts]
                        (set captured.opts opts)
                        (opts.on-chunk payload)
                        {:status 200 :body ""}))
    (let [(ok? result) (pcall f)]
      (set http.request old-request)
      (when (not ok?) (error result))
      (values result captured.opts))))

(fn stream-complete [model context payload]
  (with-stream payload
    #(openrouter.complete model context
                          {:retry-base-delay-ms 0 :retry-max-delay-ms 0}
                          (fn [_]))))

(describe "providers.openrouter reasoning mapping"
          (fn []
            (it "omits reasoning when no thinking option is set"
                (fn []
                  (assert.is_nil (openrouter.reasoning-config {}))
                  (assert.is_nil (. (request-body "openai/gpt-6-sol"
                                                  {:messages []} {})
                                    :reasoning))))
            (it "maps each thinking level to reasoning.effort and off to the model default"
                (fn []
                  (each [_ level (ipairs [:minimal :low :medium :high :xhigh])]
                    (assert.are.same {:effort level}
                                     (openrouter.reasoning-config {:thinking-level level})))
                  (assert.is_nil (openrouter.reasoning-config {:thinking-level :off}))))
            (it "sends no reasoning object for a saved thinking level of off"
                (fn []
                  ;; Gemini rejects `enabled: false` ("Reasoning is mandatory"), so a
                  ;; global defaultThinking off must not disable reasoning.
                  (let [opts (thinking.level->provider-options :off
                                                               :openrouter-completions)
                        body (request-body "google/gemini-3.8-flash"
                                           {:messages [(types.user-message "hi")]}
                                           opts)]
                    (assert.is_nil body.reasoning)
                    (assert.is_nil body.reasoning_effort))))
            (it "disables reasoning only through an explicit reasoning effort"
                (fn []
                  (each [_ effort (ipairs [:none :off :NONE])]
                    (assert.are.same {:enabled false}
                                     (openrouter.reasoning-config {:reasoning-effort effort
                                                                   :thinking-level :high})))
                  (assert.are.same {:enabled false}
                                   (. (request-body "openai/gpt-6-sol"
                                                    {:messages []}
                                                    {:reasoning-effort :none
                                                     :thinking-level :off})
                                      :reasoning))))
            (it "prefers the exact escape hatches over the level"
                (fn []
                  (assert.are.same {:max_tokens 4096}
                                   (openrouter.reasoning-config {:thinking-budget 4096
                                                                 :reasoning-effort :low
                                                                 :thinking-level :high}))
                  (assert.are.same {:effort :max}
                                   (openrouter.reasoning-config {:reasoning-effort :max
                                                                 :thinking-level :low}))
                  (assert.are.same {:enabled false}
                                   (openrouter.reasoning-config {:reasoning-effort :none}))))
            (it "drops an effort OpenRouter does not accept and falls back to the level"
                (fn []
                  (assert.are.same {:effort :low}
                                   (openrouter.reasoning-config {:reasoning-effort :bogus
                                                                 :thinking-level :low}))
                  (assert.is_nil (openrouter.reasoning-config {:reasoning-effort :bogus}))))
            (it "sends the reasoning object and never top-level reasoning_effort"
                (fn []
                  (let [body (request-body "openai/gpt-6-sol" {:messages []}
                                           {:reasoning-effort :high})]
                    (assert.are.same {:effort :high} body.reasoning)
                    (assert.is_nil body.reasoning_effort))
                  (let [body (request-body "openai/gpt-6-sol" {:messages []}
                                           {:thinking-level :low})]
                    (assert.are.same {:effort :low} body.reasoning)
                    (assert.is_nil body.reasoning_effort))))))

(describe "providers.openrouter request policy"
          (fn []
            (it "requires every parameter, uses max_tokens, and drops the default parallel flag"
                (fn []
                  (let [body (request-body "moonshotai/kimi-k3"
                                           {:messages [(types.user-message "hi")]
                                            :tools TOOLS}
                                           {:max-tokens 2048})]
                    (assert.are.same {:require_parameters true} body.provider)
                    (assert.are.equal 2048 body.max_tokens)
                    (assert.is_nil body.max_completion_tokens)
                    (assert.is_nil body.parallel_tool_calls)
                    (assert.are.equal :auto body.tool_choice))
                  (let [body (request-body "moonshotai/kimi-k3"
                                           {:messages [] :tools TOOLS}
                                           {:parallel-tool-calls false})]
                    (assert.is_false body.parallel_tool_calls))))
            (it "pins the session for sticky routing"
                (fn []
                  (let [body (request-body "openai/gpt-6-sol" {:messages []}
                                           {:prompt-cache-key "sess-123"})]
                    (assert.are.equal "sess-123" body.session_id))
                  (let [body (request-body "openai/gpt-6-sol" {:messages []}
                                           {:prompt-cache-key (string.rep "x"
                                                                          300)})]
                    (assert.are.equal 256 (length body.session_id)))))
            (it "adds cache_control to the system prompt and latest tool message for Anthropic"
                (fn []
                  (let [asst (types.assistant-message {:api :openrouter-completions
                                                       :provider :openrouter
                                                       :model "m"
                                                       :content [(types.tool-call-block "call-1"
                                                                                        "ls"
                                                                                        {})]
                                                       :stop-reason :tool-use})
                        result (types.tool-result-message {:tool-call-id "call-1"
                                                           :tool-name "ls"
                                                           :content [(types.text-block "a.txt")]
                                                           :is-error? false})
                        body (request-body "anthropic/claude-sonnet-5"
                                           {:system-prompt "be terse"
                                            :messages [(types.user-message "list")
                                                       asst
                                                       result]})
                        system (. body.messages 1)
                        user (. body.messages 2)
                        tool (. body.messages 4)]
                    (assert.are.same [{:type :text
                                       :text "be terse"
                                       :cache_control {:type :ephemeral}}]
                                     system.content)
                    (assert.are.equal "list" user.content)
                    (assert.are.equal :tool tool.role)
                    (assert.are.same [{:type :text
                                       :text "a.txt"
                                       :cache_control {:type :ephemeral}}]
                                     tool.content))))
            (it "marks the latest user message for Google models"
                (fn []
                  (let [body (request-body "google/gemini-3.8-flash"
                                           {:messages [(types.user-message "hi")]})]
                    (assert.are.same {:type :ephemeral}
                                     (. body.messages 1 :content 1
                                        :cache_control)))))
            (it "leaves content as plain strings for other vendors"
                (fn []
                  (let [body (request-body "openai/gpt-6-sol"
                                           {:system-prompt "be terse"
                                            :messages [(types.user-message "hi")]})]
                    (assert.are.equal "be terse" (. body.messages 1 :content))
                    (assert.are.equal "hi" (. body.messages 2 :content)))))
            (it "targets the OpenRouter endpoint with attribution and bearer auth"
                (fn []
                  (let [opts (openrouter.build-request-opts "openai/gpt-6-sol"
                                                            {:messages []}
                                                            {:api-key "sk-or-test"}
                                                            (fn [_]))]
                    (assert.are.equal "https://openrouter.ai/api/v1/chat/completions"
                                      opts.url)
                    (assert.are.equal "Bearer sk-or-test"
                                      opts.headers.authorization)
                    (assert.are.equal "https://github.com/acmiyaguchi/fen"
                                      (. opts.headers :http-referer))
                    (assert.are.equal "fen"
                                      (. opts.headers :x-openrouter-title))
                    (assert.are.equal "text/event-stream" opts.headers.accept))))))

(describe "providers.openrouter reasoning_details"
          (fn []
            (it "merges streamed Anthropic thinking fragments and echoes them unchanged"
                (fn []
                  (let [payload (sse {:choices [{:delta {:reasoning "Let me "
                                                         :reasoning_details [{:type "reasoning.text"
                                                                              :text "Let me "
                                                                              :format "anthropic-claude-v1"
                                                                              :index 0}]}}]}
                                     {:choices [{:delta {:reasoning "look."
                                                         :reasoning_details [{:type "reasoning.text"
                                                                              :text "look."
                                                                              :format "anthropic-claude-v1"
                                                                              :index 0}]}}]}
                                     {:choices [{:delta {:reasoning_details [{:type "reasoning.text"
                                                                              :signature "sig-abc"
                                                                              :format "anthropic-claude-v1"
                                                                              :index 0}]}}]}
                                     {:choices [{:delta {:tool_calls [{:index 0
                                                                       :id "toolu_1"
                                                                       :type "function"
                                                                       :function {:name "ls"
                                                                                  :arguments "{}"}}]}}]}
                                     {:choices [{:delta {}
                                                 :finish_reason "tool_calls"}]
                                      :usage {:prompt_tokens 100
                                              :completion_tokens 5
                                              :total_tokens 105
                                              :prompt_tokens_details {:cached_tokens 60
                                                                      :cache_write_tokens 30}}})
                        asst (stream-complete "anthropic/claude-sonnet-5"
                                              {:messages [(types.user-message "list")]}
                                              payload)
                        thinking (. (types.assistant-thinking asst) 1)
                        expected [{:type "reasoning.text"
                                   :text "Let me look."
                                   :signature "sig-abc"
                                   :format "anthropic-claude-v1"
                                   :index 0}]]
                    (assert.are.equal :openrouter asst.provider)
                    (assert.are.equal :openrouter-completions asst.api)
                    (assert.are.equal :tool-use asst.stop-reason)
                    (assert.are.equal "Let me look." thinking.thinking)
                    (assert.are.same expected
                                     (json.decode thinking.thinking-signature))
                    (assert.are.same {:input 10
                                      :output 5
                                      :cache-read 60
                                      :cache-write 30
                                      :total-tokens 105}
                                     asst.usage)
                    (let [result (types.tool-result-message {:tool-call-id "toolu_1"
                                                             :tool-name "ls"
                                                             :content [(types.text-block "a.txt")]
                                                             :is-error? false})
                          body (request-body "anthropic/claude-sonnet-5"
                                             {:messages [(types.user-message "list")
                                                         asst
                                                         result]})
                          echoed (. body.messages 2)]
                      (assert.are.equal :assistant echoed.role)
                      (assert.are.same expected echoed.reasoning_details)
                      (assert.is_nil echoed.reasoning)
                      (assert.are.equal "toolu_1" (. echoed.tool_calls 1 :id))))))
            (it "keeps opaque Gemini signatures on a tool-only turn"
                (fn []
                  (let [detail {:type "reasoning.encrypted"
                                :data "AY89opaque"
                                :format "google-gemini-v1"
                                :id "call_1"
                                :index 0}
                        payload (sse {:choices [{:delta {:content ""
                                                         :reasoning json.null
                                                         :reasoning_details [detail]}}]}
                                     {:choices [{:delta {:tool_calls [{:index 0
                                                                       :id "call_1"
                                                                       :type "function"
                                                                       :function {:name "ls"
                                                                                  :arguments "{}"}}]}}]}
                                     {:choices [{:delta {}
                                                 :finish_reason "tool_calls"}]})
                        asst (stream-complete "google/gemini-3.8-flash"
                                              {:messages []} payload)
                        thinking (types.assistant-thinking asst)]
                    (assert.are.equal 1 (length thinking))
                    (assert.are.equal "" (. thinking 1 :thinking))
                    (assert.are.same [detail]
                                     (json.decode (. thinking 1
                                                     :thinking-signature)))
                    (let [body (request-body "google/gemini-3.8-flash"
                                             {:messages [(types.user-message "go")
                                                         asst]})]
                      (assert.are.same [detail]
                                       (. body.messages 2 :reasoning_details))))))
            (it "captures reasoning_details from a non-streaming response"
                (fn []
                  (let [old-request http.request
                        detail {:type "reasoning.summary"
                                :summary "thought"
                                :format "openai-responses-v1"
                                :index 0}]
                    (set http.request
                         (fn [_]
                           {:status 200
                            :body (json.encode {:choices [{:message {:role "assistant"
                                                                     :content "done"
                                                                     :reasoning "thought"
                                                                     :reasoning_details [detail]}
                                                           :finish_reason "stop"}]})}))
                    (let [asst (openrouter.complete "openai/gpt-6-sol"
                                                    {:messages []}
                                                    {:retry-base-delay-ms 0})]
                      (set http.request old-request)
                      (assert.are.equal :openrouter asst.provider)
                      (assert.are.equal "done" (types.assistant-text asst))
                      (assert.are.same [detail]
                                       (json.decode (. (types.assistant-thinking asst)
                                                       1 :thinking-signature)))))))))

(describe "providers.openrouter stream errors"
          (fn []
            (it "surfaces a mid-stream error chunk as the assistant error message"
                (fn []
                  (let [payload (sse {:choices [{:delta {:content "par"}}]}
                                     {:error {:code "server_error"
                                              :message "Provider disconnected unexpectedly"}
                                      :choices [{:delta {:content ""}
                                                 :finish_reason "error"}]})
                        asst (stream-complete "openai/gpt-6-sol" {:messages []}
                                              payload)]
                    (assert.are.equal :error asst.stop-reason)
                    (assert.are.equal "Provider error (server_error): Provider disconnected unexpectedly"
                                      asst.error-message))))))

(fn catalog-response [ids ?params]
  "A /models body listing ids; ?params maps an id to its supported_parameters
   (default: tools and reasoning)."
  {:status 200
   :headers {}
   :body (json.encode {:data (icollect [_ id (ipairs ids)]
                               {:id id
                                :context_length 1000000
                                :supported_parameters (or (?. ?params id)
                                                          ["tools" "reasoning"])})})})

(fn with-catalog [response f]
  (let [old-request http.request]
    (set http.request (fn [_] response))
    (let [(ok? result) (pcall f)]
      (set http.request old-request)
      (when (not ok?) (error result))
      result)))

(describe "providers.openrouter curated catalog"
          (fn []
            (it "returns only curated ids that are live, in curated order"
                (fn []
                  (let [old-request http.request
                        captured {}]
                    (set http.request
                         (fn [opts]
                           (set captured.opts opts)
                           (catalog-response ["zz/unlisted"
                                              "anthropic/claude-sonnet-5"
                                              "google/gemini-3.8-flash"
                                              "other/model"])))
                    (let [models (openrouter.list-models {:api-key "sk-or-test"})]
                      (set http.request old-request)
                      (assert.are.equal "https://openrouter.ai/api/v1/models"
                                        captured.opts.url)
                      (assert.are.equal "Bearer sk-or-test"
                                        captured.opts.headers.authorization)
                      (assert.are.same [{:id "google/gemini-3.8-flash"
                                         :context-window 1000000
                                         :reasoning? true}
                                        {:id "anthropic/claude-sonnet-5"
                                         :context-window 1000000
                                         :reasoning? true}]
                                       models)))))
            (it "keeps every id a models.json override declares, in declared order"
                (fn []
                  (let [models (with-catalog (catalog-response ["anthropic/claude-sonnet-5"
                                                                "x-ai/grok-4.7"
                                                                "qwen/qwen3.8-flash"])
                                 #(openrouter.list-models {:models [{:id "x-ai/grok-4.7"}
                                                                    {:id "my-org/private-byok"}
                                                                    "qwen/qwen3.8-flash:nitro"]}))]
                    ;; Off-catalog ids (private/BYOK) stay; a `:nitro` variant is
                    ;; enriched from its base model's entry.
                    (assert.are.same [{:id "x-ai/grok-4.7"
                                       :context-window 1000000
                                       :reasoning? true}
                                      {:id "my-org/private-byok"}
                                      {:id "qwen/qwen3.8-flash:nitro"
                                       :context-window 1000000
                                       :reasoning? true}]
                                     models))))
            (it "keeps a declared list even when none of it is in the live catalog"
                (fn []
                  (let [models (with-catalog (catalog-response ["other/model"])
                                 #(openrouter.list-models {:models [{:id "only/private"}]}))]
                    (assert.are.same [{:id "only/private"}] models))))
            (it "still filters the curated list to live ids"
                (fn []
                  (let [models (with-catalog (catalog-response ["qwen/qwen3.8-flash"
                                                                "qwen/qwen3.8-flash:nitro"])
                                 #(openrouter.list-models {}))]
                    (assert.are.same ["qwen/qwen3.8-flash"]
                                     (icollect [_ m (ipairs models)] m.id)))))
            (it "omits reasoning for a model the live catalog marks as non-reasoning"
                (fn []
                  (with-catalog (catalog-response ["mistralai/devstral-2512"
                                                   "google/gemini-3.8-flash"]
                                                  {"mistralai/devstral-2512" ["tools"
                                                                              "max_tokens"]})
                    #(openrouter.list-models {:models [{:id "mistralai/devstral-2512"}
                                                       {:id "google/gemini-3.8-flash"}]}))
                  (let [opts (thinking.level->provider-options :high
                                                               :openrouter-completions)
                        plain (request-body "mistralai/devstral-2512"
                                            {:messages []} opts)
                        exact (request-body "mistralai/devstral-2512"
                                            {:messages []}
                                            {:reasoning-effort :none
                                             :thinking-budget 1024})
                        thinker (request-body "google/gemini-3.8-flash"
                                              {:messages []} opts)
                        unknown (request-body "vendor/never-listed"
                                              {:messages []} opts)]
                    (assert.is_nil plain.reasoning)
                    (assert.is_nil exact.reasoning)
                    (assert.are.same {:effort :high} thinker.reasoning)
                    ;; Unknown support keeps sending it: curated models all reason.
                    (assert.are.same {:effort :high} unknown.reasoning))))
            (it "returns structured secret-free failure reasons"
                (fn []
                  (let [old-request http.request]
                    (set http.request
                         (fn [_]
                           {:status 401 :headers {} :body "token=sk-secret"}))
                    (let [(ok? err) (pcall openrouter.list-models
                                           {:api-key "sk-secret"})]
                      (assert.is_false ok?)
                      (assert.are.equal :authentication-failed err.reason))
                    (set http.request
                         (fn [_] {:status 200 :headers {} :body "not json"}))
                    (let [(ok? err) (pcall openrouter.list-models {})]
                      (assert.is_false ok?)
                      (assert.are.equal :request-failed err.reason))
                    (set http.request (fn [_] {:error "transport secret"}))
                    (let [(ok? err) (pcall openrouter.list-models {})]
                      (set http.request old-request)
                      (assert.is_false ok?)
                      (assert.are.equal :request-failed err.reason)))))))

(describe "providers.openrouter registration"
          (fn []
            (it "registers the curated provider with its own api"
                (fn []
                  (let [captured {}]
                    (init.register {:register (fn [kind spec]
                                                (set captured.kind kind)
                                                (set captured.spec spec))})
                    (assert.are.equal :provider captured.kind)
                    (assert.are.equal :openrouter captured.spec.name)
                    (assert.are.equal :openrouter-completions captured.spec.api)
                    (assert.are.equal :OPENROUTER_API_KEY
                                      captured.spec.api-key-var)
                    (assert.are.equal (. openrouter.models 1 :id)
                                      captured.spec.default-model)
                    (assert.are.same openrouter.models captured.spec.models)
                    (assert.is_function captured.spec.complete)
                    (assert.is_function captured.spec.list-models))))))

(describe "providers.openrouter models.json delegation"
          (fn []
            (var tmp nil)
            (var models-mod nil)
            (before_each (fn []
                           (test-api.reset!)
                           (set tmp (h.make-tmpdir))
                           (h.stub-getenv! (fn [name orig]
                                             (if (= name :XDG_CONFIG_HOME) tmp
                                                 (= name :HOME) tmp
                                                 (= name :OPENROUTER_API_KEY)
                                                 "sk-or-env" (orig name))))
                           (set models-mod
                                (h.reload-module :fen.core.llm.models))
                           (init.register {:register (fn [kind spec]
                                                       (register.register kind
                                                                          spec
                                                                          :provider_openrouter))})))
            (after_each (fn []
                          (h.restore-getenv!)
                          (test-api.reset!)
                          (when tmp (h.rmtree tmp))))
            (it "overrides the built-in by name, delegates to the adapter, and lists only the user's models"
                (fn []
                  (h.write-file (.. tmp "/fen/models.json")
                                (.. "{\"providers\": {\"openrouter\": {"
                                    "\"api\": \"openrouter-completions\","
                                    "\"baseUrl\": \"https://openrouter.ai/api/v1\","
                                    "\"apiKey\": \"OPENROUTER_API_KEY\","
                                    "\"models\": [{\"id\": \"x-ai/grok-4.7\"}]"
                                    "}}}"))
                  (assert.are.equal 1 (models-mod.register-providers!))
                  (let [old-request http.request
                        seen {}]
                    (set http.request
                         (fn [opts]
                           (set seen.auth opts.headers.authorization)
                           (catalog-response ["anthropic/claude-sonnet-5"
                                              "x-ai/grok-4.7"])))
                    (let [refs (models-mod.available-models {})]
                      (set http.request old-request)
                      (var mine [])
                      (each [_ ref (ipairs refs)]
                        (when (= (tostring ref.provider) "openrouter")
                          (table.insert mine ref.id)))
                      (assert.are.equal "Bearer sk-or-env" seen.auth)
                      (assert.are.same ["x-ai/grok-4.7"] mine)))))))
