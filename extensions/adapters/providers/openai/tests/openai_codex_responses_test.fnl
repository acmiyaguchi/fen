;; Codex provider tests. Covers Codex-specific event aliasing, header
;; construction, URL building, and the option-merging defaults. The
;; reducer itself is exhaustively covered by the openai package's responses test.

(local codex (require :fen.extensions.provider_openai.openai_codex_responses))
(local shared (require :fen.extensions.provider_openai.openai_responses_shared))
(local types (require :fen.core.types))
(local json (require :fen.util.json))
(local http (require :fen.util.http))

(describe "providers.openai_codex_responses.build-url"
  (fn []
    (it "appends /codex/responses to the chatgpt backend-api root"
      (fn []
        (assert.are.equal "https://chatgpt.com/backend-api/codex/responses"
                          (codex.build-url "https://chatgpt.com/backend-api"))))

    (it "respects a fully-qualified codex URL"
      (fn []
        (assert.are.equal "https://chatgpt.com/backend-api/codex/responses"
                          (codex.build-url "https://chatgpt.com/backend-api/codex/responses"))))))

(describe "providers.openai_codex_responses.build-headers"
  (fn []
    (it "carries authorization, chatgpt-account-id, originator, openai-beta"
      (fn []
        (let [headers (codex.build-headers {:access "AT" :accountId "acc_1"})]
          (assert.are.equal "Bearer AT" headers.authorization)
          (assert.are.equal "acc_1" headers.chatgpt-account-id)
          (assert.are.equal "pi" headers.originator)
          (assert.are.equal "responses=experimental" headers.openai-beta)
          (assert.are.equal "text/event-stream" headers.accept)
          (assert.are.equal "application/json" headers.content-type))))))

(describe "providers.openai_codex_responses.map-codex-event"
  (fn []
    (it "rewrites response.done to response.completed"
      (fn []
        (let [in {:type :response.done :response {:id "r1" :status :completed}}
              out (codex.map-codex-event in)]
          (assert.are.equal :response.completed out.type)
          (assert.are.equal "r1" out.response.id))))

    (it "rewrites response.incomplete to response.completed"
      (fn []
        (let [in {:type :response.incomplete :response {:id "r2"}}
              out (codex.map-codex-event in)]
          (assert.are.equal :response.completed out.type))))

    (it "passes other event types through unchanged"
      (fn []
        (let [in {:type :response.output_text.delta :delta "hi"}
              out (codex.map-codex-event in)]
          (assert.are.equal :response.output_text.delta out.type)
          (assert.are.equal "hi" out.delta))))

    (it "feeds aliased events through the shared reducer correctly"
      (fn []
        (let [state (shared.new-stream-state "gpt-5.5")
              events
              [{:type :response.output_item.added
                :item {:type :message :id "msg_1" :role :assistant :content []}}
               {:type :response.output_text.delta :delta "ok"}
               {:type :response.output_item.done
                :item {:type :message :id "msg_1" :role :assistant
                       :content [{:type :output_text :text "ok"}]}}
               ;; Codex alias — would be unhandled by the reducer
               ;; if we forwarded as-is.
               {:type :response.done
                :response {:status :completed
                           :usage {:input_tokens 0 :output_tokens 0
                                   :total_tokens 0}}}]]
          (each [_ ev (ipairs events)]
            (shared.process-event! state (codex.map-codex-event ev) nil))
          ;; The response.done alias maps to response.completed, so it must
          ;; mark the terminal flag finalize-stream relies on to tell a real
          ;; completion from a silently-dropped stream.
          (assert.is_true state.saw-terminal?)
          (let [asst (shared.finalize-stream-state state :openai-codex-responses
                                                    :openai-codex nil)]
            (assert.are.equal :stop asst.stop-reason)
            (assert.are.equal "ok" (. asst.content 1 :text))))))))

(describe "providers.openai_codex_responses.model catalog"
  (fn []
    (it "builds the Codex model catalog URL with a client version"
      (fn []
        (assert.are.equal "https://chatgpt.com/backend-api/codex/models?client_version=0.124.0"
                          (codex.build-models-url "https://chatgpt.com/backend-api"))
        (assert.are.equal "https://chatgpt.com/backend-api/codex/models?client_version=0.124.0"
                          (codex.build-models-url "https://chatgpt.com/backend-api/codex/responses"))))

    (it "keeps only listed models supported by the API"
      (fn []
        (let [models (codex.parse-models
                       {:models [{:slug "gpt-5.5" :visibility :list :supported_in_api true}
                                 {:slug "spark" :visibility :list :supported_in_api false}
                                 {:slug "codex-auto-review" :visibility :hide :supported_in_api true}]})]
          (assert.are.equal 1 (length models))
          (assert.are.equal "gpt-5.5" (. models 1 :id)))))

    (it "fetches and parses the authenticated catalog"
      (fn []
        (let [old-request http.request
              captured {}]
          (set http.request
               (fn [opts]
                 (tset captured :opts opts)
                 {:status 200
                  :headers {}
                  :body (json.encode {:models [{:slug "gpt-5.4" :visibility :list
                                                :supported_in_api true}]})}))
          (let [models (codex.list-models {:creds {:access "AT" :accountId "acc"}
                                           :client-version "1.0.0"})]
            (set http.request old-request)
            (assert.are.equal :GET captured.opts.method)
            (assert.are.equal "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0"
                              captured.opts.url)
            (assert.are.equal "Bearer AT" captured.opts.headers.authorization)
            (assert.are.equal "acc" captured.opts.headers.chatgpt-account-id)
            (assert.are.equal "gpt-5.4" (. models 1 :id)))))))

(describe "providers.openai_codex_responses.merge-options"
  (fn []
    (it "defaults include to [reasoning.encrypted_content]"
      (fn []
        (let [out (codex.merge-options {})]
          (assert.are.equal 1 (length out.include))
          (assert.are.equal "reasoning.encrypted_content" (. out.include 1)))))

    (it "preserves a caller-supplied include[]"
      (fn []
        (let [out (codex.merge-options {:include ["custom.flag"]})]
          (assert.are.equal 1 (length out.include))
          (assert.are.equal "custom.flag" (. out.include 1)))))

    (it "does not mutate the caller's options table"
      (fn []
        (let [in {}
              out (codex.merge-options in)]
          (assert.is_nil in.include)
          (assert.is_table out.include))))))

(describe "providers.openai_codex_responses.complete retry"
  (fn []
    (it "retries no-status transport failures before finalizing the stream"
      (fn []
        (let [old-request http.request
              calls []
              events []]
          (set http.request
               (fn [opts]
                 (table.insert calls opts)
                 (if (= (length calls) 1)
                     {:error "legacy wording not needed when curl code is present" :curl-code 52}
                     (do
                       (opts.on-chunk "data: {\"type\":\"response.done\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0,\"total_tokens\":1}}}\n\n")
                       {:status 200 :body "" :headers {}}))))
          (let [asst (codex.complete
                       "gpt-5.5" {:messages [] :tools []}
                       {:creds {:access "AT" :accountId "acc"}
                        :retry-base-delay-ms 0
                        :retry-max-delay-ms 0}
                       #(table.insert events $1))]
            (set http.request old-request)
            (assert.are.equal 2 (length calls))
            (assert.are.equal :stop asst.stop-reason)
            (assert.are.equal 1 asst.usage.input)
            (assert.are.equal :provider-retry (. events 2 :type))
            (assert.are.equal :openai-codex (. events 2 :provider)))))))))
