(local test-api (require :fen.core.extensions.test_api))
(local ext-state (require :fen.core.extensions.state))
(local events (require :fen.core.extensions.events))
(local json (require :fen.util.json))
(local manifest (require :fen.extensions.decide.manifest))

(local original-http (. package.loaded :fen.util.http))

(local ctx {:calls [] :logs [] :settings {} :respond nil})

(local QUESTIONS
       {:a {:type :noul
            :instructions "Is the task finished?"
            :criteria {:true "The task is finished." :false "Work remains."}}
        :b {:type :choice
            :instructions "Classify the input."
            :criteria {:cancel "Stop the current work."
                       :correction "Fix the current work."
                       :follow-up "Queue new work."}}})

(local OK-BODY (json.encode {:model "typesafe/jev-1.13-20260917"
                             :answers {:a {:type :noul :noul 0.99}
                                       :b {:type :choice
                                           :choice :follow-up
                                           :probabilities {:cancel 0
                                                           :correction 0
                                                           :follow-up 1}
                                           :confidence 0.99}}
                             :usage {:input_tokens 447
                                     :output_tokens 59
                                     :cost 0.000018774}}))

(local OPENAI-OK-BODY
       (json.encode {:model "gpt-6-luna"
                     :answers [{:type "predicate" :name "a" :probability 0.99}
                               {:type "choice"
                                :name "b"
                                :choice "follow-up"
                                :probabilities [{:value "cancel"
                                                 :probability 0}
                                                {:value "correction"
                                                 :probability 0}
                                                {:value "follow-up"
                                                 :probability 1}]
                                :confidence 0.99}]
                     :usage {:input_tokens 320 :total_tokens 320}}))

(fn ok-response [req]
  (let [body (if (and req req.url (string.find req.url "api.openai.com" 1 true))
                 OPENAI-OK-BODY
                 OK-BODY)]
    {:status 200 :body body :headers {}}))

(fn clear-modules! []
  (tset package.loaded :fen.extensions.decide nil)
  (tset package.loaded :fen.extensions.decide.service nil)
  (tset package.loaded :fen.extensions.decide.jev nil)
  (tset package.loaded :fen.extensions.decide.openai nil))

(fn fresh! [?opts]
  "Load decide with a mocked transport; returns the service."
  (let [opts (or ?opts {})]
    (test-api.reset!)
    (clear-modules!)
    (set ctx.calls [])
    (set ctx.logs [])
    (set ctx.settings (or opts.settings {}))
    (set ctx.respond (or opts.respond ok-response))
    (tset package.loaded :fen.util.http
          {:request (fn [req]
                      (table.insert ctx.calls req)
                      (ctx.respond req))})
    (let [store (require :fen.extensions.decide.state)]
      (set store.api nil)
      (set store.tasks []))
    (when (not= opts.key false)
      (tset ext-state.providers :openrouter
            {:api (or opts.provider-api :openrouter-completions)
             :api-key (or opts.key "sk-test")})
      (when (not= opts.openai-key false)
        (tset ext-state.providers :openai
              {:api :openai-completions
               :api-key (or opts.openai-key "sk-openai-test")})))
    (let [api (test-api.make-runtime-api :decide manifest)
          decide (require :fen.extensions.decide)]
      (set api.settings {:extension (fn [] ctx.settings)})
      (set api.log (fn [level msg] (table.insert ctx.logs {: level : msg})))
      (decide.register api)
      (require :fen.extensions.decide.service))))

(fn logged? [needle]
  (accumulate [found? false _ rec (ipairs ctx.logs)]
    (or found?
        (and (= (type rec.msg) :string)
             (not= nil (string.find rec.msg needle 1 true))))))

(fn tick! []
  (events.emit {:type :runtime-tick :busy? false}))

(describe "fen.extensions.decide.service"
          (fn []
            (after_each (fn []
                          (tset package.loaded :fen.util.http original-http)
                          (clear-modules!)
                          (test-api.reset!)))
            (it "maps noul and choice answers into Fennel shapes"
                (fn []
                  (let [service (fresh!)
                        answers (service.ask {:task "x"} QUESTIONS)]
                    (assert.are.same {:type :noul :noul 0.99} answers.a)
                    (assert.are.equal :choice answers.b.type)
                    (assert.are.equal :follow-up answers.b.choice)
                    (assert.are.equal 0.99 answers.b.confidence)
                    (assert.are.same {:cancel 0 :correction 0 :follow-up 1}
                                     answers.b.probabilities))))
            (it "sends one multi-question request with the configured model and key"
                (fn []
                  (let [service (fresh! {:settings {:model "custom/jev"
                                                    :timeoutMs 1500}})]
                    (service.ask {:task "x" :items [1 2]} QUESTIONS)
                    (assert.are.equal 1 (length ctx.calls))
                    (let [req (. ctx.calls 1)
                          body (json.decode req.body)]
                      (assert.are.equal :POST req.method)
                      (assert.are.equal "https://openrouter.ai/api/alpha/decisions"
                                        req.url)
                      (assert.are.equal "Bearer sk-test"
                                        req.headers.authorization)
                      (assert.are.equal "application/json"
                                        (. req.headers :content-type))
                      (assert.are.equal 1500 (. req :timeout-ms))
                      (assert.are.equal 1500 (. req :connect-timeout-ms))
                      (assert.are.equal "custom/jev" body.model)
                      (assert.are.equal "x" body.state.task)
                      (assert.are.equal :noul body.questions.a.type)
                      (assert.are.equal "Work remains."
                                        (. body.questions.a.criteria :false))
                      (assert.are.equal :choice body.questions.b.type)
                      (assert.are.equal "Queue new work."
                                        (. body.questions.b.criteria :follow-up))))))
            (it "defaults the model and a short timeout with a capped connect timeout"
                (fn []
                  (let [service (fresh! {:settings {:timeoutMs "fast"}})]
                    (service.ask {} QUESTIONS)
                    (let [req (. ctx.calls 1)]
                      (assert.are.equal "~typesafe/jev-latest"
                                        (. (json.decode req.body) :model))
                      (assert.are.equal 3000 (. req :timeout-ms))
                      (assert.are.equal 2000 (. req :connect-timeout-ms))))))
            (it "resolves the key from the openrouter provider's api-key-var"
                (fn []
                  (let [service (fresh! {:key false})
                        path (require :fen.util.path)
                        original-getenv path.getenv]
                    (tset ext-state.providers :openrouter
                          {:api-key-var :FEN_TEST_DECIDE_KEY})
                    (set path.getenv
                         (fn [name]
                           (if (= name :FEN_TEST_DECIDE_KEY) "sk-env"
                               (original-getenv name))))
                    (let [(ok? answers) (pcall service.ask {} QUESTIONS)]
                      (set path.getenv original-getenv)
                      (assert.is_true ok? answers)
                      (assert.is_table answers)
                      (assert.are.equal "Bearer sk-env"
                                        (. ctx.calls 1 :headers :authorization))))))
            (it "returns nil without a request when the extension is disabled"
                (fn []
                  (let [service (fresh!)
                        seen []]
                    (tset ext-state.extensions :decide {:status :disabled})
                    (assert.is_false (service.enabled?))
                    (assert.is_nil (service.ask {} QUESTIONS))
                    (service.ask-async! {} QUESTIONS
                                        (fn [answers]
                                          (table.insert seen {: answers})))
                    (assert.are.equal 1 (length seen))
                    (assert.is_nil (. seen 1 :answers))
                    (assert.are.equal 0 (length ctx.calls)))))
            (it "returns nil without a request when no OpenRouter key is configured"
                (fn []
                  (let [service (fresh! {:key false})]
                    (assert.is_nil (service.ask {} QUESTIONS))
                    (assert.are.equal 0 (length ctx.calls))
                    (assert.is_true (logged? "no OpenRouter API key")))))
            (it "rejects invalid questions without a request"
                (fn []
                  (let [service (fresh!)
                        criteria {:true "yes" :false "no"}]
                    (each [_ qs (ipairs [{}
                                         {:a {:type :score
                                              :instructions "?"
                                              :criteria criteria}}
                                         {:a {:type :noul
                                              :instructions ""
                                              :criteria criteria}}
                                         {:a {:type :noul
                                              :instructions "?"
                                              :criteria {:true "yes"}}}
                                         {:a {:type :choice
                                              :instructions "?"
                                              :criteria {}}}
                                         [{:type :noul
                                           :instructions "?"
                                           :criteria criteria}]])]
                      (assert.is_nil (service.ask {} qs)))
                    (assert.are.equal 0 (length ctx.calls))
                    (assert.is_true (logged? "invalid questions")))))
            (it "skips requests over the size guard"
                (fn []
                  (let [service (fresh!)
                        big {:blob (string.rep "x"
                                               (+ service.max-request-bytes 1))}]
                    (assert.is_nil (service.ask big QUESTIONS))
                    (assert.are.equal 0 (length ctx.calls))
                    (assert.is_true (logged? "guard")))))
            (it "returns nil for unencodable state"
                (fn []
                  (let [service (fresh!)]
                    (assert.is_nil (service.ask {:f (fn [] nil)} QUESTIONS))
                    (assert.are.equal 0 (length ctx.calls)))))
            (it "maps transport, HTTP, and response failures to nil"
                (fn []
                  (each [_ c (ipairs [{:resp {:error "Timeout was reached"
                                              :curl-code 28}
                                       :log "Timeout"}
                                      {:resp {:status 400
                                              :body "{\"error\":{\"message\":\"max_tokens_exceeded\",\"code\":400}}"}
                                       :log "HTTP 400: max_tokens_exceeded"}
                                      {:resp {:status 502
                                              :body "<html>bad gateway</html>"}
                                       :log "HTTP 502"}
                                      {:resp {:status 200 :body "not json"}
                                       :log "malformed response"}
                                      {:resp {:status 200
                                              :body "{\"answers\":{\"a\":{\"type\":\"noul\",\"noul\":0.5}}}"}
                                       :log "missing or malformed answer: b"}
                                      {:resp {:status 200
                                              :body "{\"answers\":{\"a\":{\"type\":\"noul\",\"noul\":0.5},\"b\":{\"type\":\"choice\",\"choice\":\"other\",\"probabilities\":{\"other\":1},\"confidence\":0.9}}}"}
                                       :log "missing or malformed answer: b"}])]
                    (let [service (fresh! {:respond (fn [_] c.resp)})]
                      (assert.is_nil (service.ask {} QUESTIONS))
                      (assert.are.equal 1 (length ctx.calls))
                      (assert.is_true (logged? c.log) c.log)))))
            (it "rejects the whole response when any answer is malformed"
                (fn []
                  (let [good-a {:type :noul :noul 0.5}
                        good-b {:type :choice
                                :choice :cancel
                                :probabilities {:cancel 0.9
                                                :correction 0.05
                                                :follow-up 0.05}
                                :confidence 0.9}
                        without (fn [t k]
                                  (collect [kk v (pairs t)]
                                    (when (not= kk k) (values kk v))))
                        with (fn [t k v]
                               (let [out (collect [kk vv (pairs t)] kk vv)]
                                 (tset out k v)
                                 out))]
                    (each [label answers (pairs {"missing type" {:a (without good-a
                                                                      :type)
                                                                 :b good-b}
                                                 "mismatched type" {:a (with good-a
                                                                         :type
                                                                         :choice)
                                                                    :b good-b}
                                                 "noul above 1" {:a (with good-a
                                                                      :noul
                                                                      1.5)
                                                                 :b good-b}
                                                 "noul below 0" {:a (with good-a
                                                                      :noul
                                                                      -0.1)
                                                                 :b good-b}
                                                 "noul not a number" {:a (with good-a
                                                                           :noul
                                                                           "0.5")
                                                                      :b good-b}
                                                 "choice outside criteria" {:a good-a
                                                                            :b (with good-b
                                                                                 :choice
                                                                                 :other)}
                                                 "choice without probabilities" {:a good-a
                                                                                 :b (without good-b
                                                                                      :probabilities)}
                                                 "choice with empty probabilities" {:a good-a
                                                                                    :b (with good-b
                                                                                         :probabilities
                                                                                         {})}
                                                 "choice with out-of-range probability" {:a good-a
                                                                                         :b (with good-b
                                                                                              :probabilities
                                                                                              {:cancel 2})}
                                                 "choice without confidence" {:a good-a
                                                                              :b (without good-b
                                                                                   :confidence)}
                                                 "choice confidence above 1" {:a good-a
                                                                              :b (with good-b
                                                                                   :confidence
                                                                                   1.2)}})]
                      (let [body (json.encode {:answers answers})
                            service (fresh! {:respond (fn [_]
                                                        {:status 200
                                                         :body body})})]
                        (assert.is_nil (service.ask {} QUESTIONS) label)
                        (assert.is_true (logged? "missing or malformed answer")
                                        label)))
                    (let [body (json.encode {:answers {:a good-a :b good-b}})
                          service (fresh! {:respond (fn [_]
                                                      {:status 200 :body body})})]
                      (assert.are.same {:a good-a :b good-b}
                                       (service.ask {} QUESTIONS))))))
            (it "maps a raising transport to nil"
                (fn []
                  (let [service (fresh! {:respond (fn [_]
                                                    (error "fen_http missing"))})]
                    (assert.is_nil (service.ask {} QUESTIONS))
                    (assert.is_true (logged? "fen_http missing")))))
            (it "passes a yield function through and propagates its errors"
                (fn []
                  (let [yields {:n 0}
                        service (fresh! {:respond (fn [req]
                                                    (req.yield)
                                                    (ok-response req))})]
                    (assert.is_table (service.ask {} QUESTIONS
                                                  {:yield (fn []
                                                            (set yields.n
                                                                 (+ yields.n 1)))}))
                    (assert.are.equal 1 yields.n)
                    (let [marker {:type :test-cancel}
                          (ok? err) (pcall service.ask {} QUESTIONS
                                           {:yield (fn [] (error marker))})]
                      (assert.is_false ok?)
                      (assert.are.equal marker err)))))
            (it "ask-async! completes through runtime-tick pumping and reports once"
                (fn []
                  (let [service (fresh! {:respond (fn [req]
                                                    (req.yield)
                                                    (ok-response req))})
                        store (require :fen.extensions.decide.state)
                        seen []]
                    (assert.is_nil (service.ask-async! {} QUESTIONS
                                                       (fn [answers]
                                                         (table.insert seen
                                                                       answers))))
                    (assert.are.equal 0 (length seen))
                    (assert.are.equal 0 (length ctx.calls))
                    (tick!)
                    (assert.are.equal 1 (length ctx.calls))
                    (assert.are.equal 0 (length seen))
                    (assert.are.equal 1 (length store.tasks))
                    (tick!)
                    (assert.are.equal 1 (length seen))
                    (assert.are.equal 0.99 (. seen 1 :a :noul))
                    (assert.are.equal 0 (length store.tasks))
                    (tick!)
                    (assert.are.equal 1 (length seen)))))
            (it "re-registering finishes pending tasks with nil without resuming them"
                (fn []
                  (let [resumed {:n 0}
                        service (fresh! {:respond (fn [req]
                                                    (set resumed.n
                                                         (+ resumed.n 1))
                                                    (req.yield)
                                                    (set resumed.n
                                                         (+ resumed.n 1))
                                                    (ok-response req))})
                        store (require :fen.extensions.decide.state)
                        seen []]
                    (service.ask-async! {} QUESTIONS
                                        (fn [answers]
                                          (table.insert seen {: answers})))
                    (tick!)
                    (assert.are.equal 1 resumed.n)
                    (assert.are.equal 1 (length store.tasks))
                    (let [task (. store.tasks 1)]
                      ;; A fresh register, as /reload or disable-then-enable runs it.
                      (test-api.reset!)
                      (let [api (test-api.make-runtime-api :decide manifest)]
                        (set api.settings {:extension (fn [] ctx.settings)})
                        (set api.log
                             (fn [level msg]
                               (table.insert ctx.logs {: level : msg})))
                        ((. (require :fen.extensions.decide) :register) api))
                      (assert.are.equal 1 (length seen))
                      (assert.is_nil (. seen 1 :answers))
                      (assert.are.equal 0 (length store.tasks))
                      (tick!)
                      (tick!)
                      (assert.are.equal 1 resumed.n)
                      (assert.are.equal 1 (length seen))
                      (assert.are.equal :suspended (coroutine.status task.co))))))
            (it "ask-async! reports nil once when the decision fails"
                (fn []
                  (let [service (fresh! {:respond (fn [_]
                                                    {:status 500 :body ""})})
                        seen []]
                    (service.ask-async! {} QUESTIONS
                                        (fn [answers]
                                          (table.insert seen {: answers})))
                    (tick!)
                    (tick!)
                    (assert.are.equal 1 (length seen))
                    (assert.is_nil (. seen 1 :answers)))))
            (describe "backend selection"
                      (fn []
                        (it "defaults to Jev backend and ~typesafe/jev-latest when backend is omitted"
                            (fn []
                              (let [service (fresh!)]
                                (service.ask {} QUESTIONS)
                                (assert.are.equal 1 (length ctx.calls))
                                (let [req (. ctx.calls 1)
                                      body (json.decode req.body)]
                                  (assert.are.equal "https://openrouter.ai/api/alpha/decisions"
                                                    req.url)
                                  (assert.are.equal "~typesafe/jev-latest"
                                                    body.model)))))
                        (it "selects OpenAI backend and defaults model to gpt-6-luna"
                            (fn []
                              (let [service (fresh! {:settings {:backend "openai"}})]
                                (let [answers (service.ask {} QUESTIONS)]
                                  (assert.is_table answers)
                                  (assert.are.same {:type :noul :noul 0.99}
                                                   answers.a)
                                  (assert.are.equal "follow-up"
                                                    answers.b.choice))
                                (assert.are.equal 1 (length ctx.calls))
                                (let [req (. ctx.calls 1)
                                      body (json.decode req.body)]
                                  (assert.are.equal "https://api.openai.com/v1/decisions"
                                                    req.url)
                                  (assert.are.equal "Bearer sk-openai-test"
                                                    req.headers.authorization)
                                  (assert.are.equal "gpt-6-luna" body.model)))))
                        (it "respects explicit model with OpenAI backend"
                            (fn []
                              (let [service (fresh! {:settings {:backend :openai
                                                                :model "gpt-6-luna-custom"}})]
                                (service.ask {} QUESTIONS)
                                (let [req (. ctx.calls 1)
                                      body (json.decode req.body)]
                                  (assert.are.equal "gpt-6-luna-custom"
                                                    body.model)))))
                        (it "rejects unknown backend without network work"
                            (fn []
                              (let [service (fresh! {:settings {:backend "anthropic"}})]
                                (assert.is_nil (service.ask {} QUESTIONS))
                                (assert.are.equal 0 (length ctx.calls))
                                (assert.is_true (logged? "unknown backend: anthropic")))))))
            (describe "openai backend credentials"
                      (fn []
                        (it "resolves key from openai provider api-key-var"
                            (fn []
                              (let [service (fresh! {:key false
                                                     :settings {:backend "openai"}})
                                    path (require :fen.util.path)
                                    original-getenv path.getenv]
                                (tset ext-state.providers :openai
                                      {:api-key-var :FEN_TEST_OPENAI_KEY})
                                (set path.getenv
                                     (fn [name]
                                       (if (= name :FEN_TEST_OPENAI_KEY)
                                           "sk-env-openai"
                                           (original-getenv name))))
                                (let [(ok? answers) (pcall service.ask {}
                                                           QUESTIONS
                                                           {:yield nil})]
                                  (set path.getenv original-getenv)
                                  (assert.is_true ok? answers)
                                  (assert.is_table answers)
                                  (assert.are.equal "Bearer sk-env-openai"
                                                    (. ctx.calls 1 :headers
                                                       :authorization))))))
                        (it "resolves key from openai-responses provider when openai provider is absent"
                            (fn []
                              (let [service (fresh! {:key false
                                                     :settings {:backend "openai"}})]
                                (tset ext-state.providers :openai-responses
                                      {:api-key "sk-responses-key"})
                                (let [answers (service.ask {} QUESTIONS)]
                                  (assert.is_table answers)
                                  (assert.are.equal "Bearer sk-responses-key"
                                                    (. ctx.calls 1 :headers
                                                       :authorization))))))
                        (it "does not resolve key from openai-codex auth backend"
                            (fn []
                              (let [service (fresh! {:key false
                                                     :settings {:backend "openai"}})]
                                (tset ext-state.providers :openai-codex
                                      {:auth-backend :openai-codex})
                                (assert.is_nil (service.ask {} QUESTIONS))
                                (assert.are.equal 0 (length ctx.calls))
                                (assert.is_true (logged? "no OpenAI API key")))))
                        (it "returns nil when no OpenAI key is configured"
                            (fn []
                              (let [service (fresh! {:key false
                                                     :settings {:backend "openai"}})]
                                (assert.is_nil (service.ask {} QUESTIONS))
                                (assert.are.equal 0 (length ctx.calls))
                                (assert.is_true (logged? "no OpenAI API key")))))))
            (describe "openai backend error and refusal handling"
                      (fn []
                        (it "handles refusal by logging and returning nil"
                            (fn []
                              (let [service (fresh! {:settings {:backend "openai"}
                                                     :respond (fn [_]
                                                                {:status 200
                                                                 :body (json.encode {:answers [{:type "refusal"
                                                                                                :name "a"
                                                                                                :refusal "Refused"}]})})})]
                                (assert.is_nil (service.ask {} QUESTIONS))
                                (assert.are.equal 1 (length ctx.calls))
                                (assert.is_true (logged? "refusal for a")))))
                        (it "handles duplicate answers by logging and returning nil"
                            (fn []
                              (let [service (fresh! {:settings {:backend "openai"}
                                                     :respond (fn [_]
                                                                {:status 200
                                                                 :body (json.encode {:answers [{:type "predicate"
                                                                                                :name "a"
                                                                                                :probability 0.5}
                                                                                               {:type "predicate"
                                                                                                :name "a"
                                                                                                :probability 0.8}
                                                                                               {:type "choice"
                                                                                                :name "b"
                                                                                                :choice "cancel"
                                                                                                :probabilities [{:value "cancel"
                                                                                                                 :probability 1}]}]})})})]
                                (assert.is_nil (service.ask {} QUESTIONS))
                                (assert.is_true (logged? "duplicate answer for a")))))
                        (it "handles HTTP error by logging and returning nil"
                            (fn []
                              (let [service (fresh! {:settings {:backend "openai"}
                                                     :respond (fn [_]
                                                                {:status 429
                                                                 :body (json.encode {:error {:message "rate limit"
                                                                                             :code 429}})})})]
                                (assert.is_nil (service.ask {} QUESTIONS))
                                (assert.is_true (logged? "HTTP 429: rate limit")))))))
            (describe "openai backend async and size guards"
                      (fn []
                        (it "skips requests over size guard with openai backend"
                            (fn []
                              (let [service (fresh! {:settings {:backend "openai"}})
                                    big {:blob (string.rep "x"
                                                           (+ service.max-request-bytes
                                                              1))}]
                                (assert.is_nil (service.ask big QUESTIONS))
                                (assert.are.equal 0 (length ctx.calls))
                                (assert.is_true (logged? "guard")))))
                        (it "ask-async! completes through runtime-tick with openai backend"
                            (fn []
                              (let [service (fresh! {:settings {:backend "openai"}
                                                     :respond (fn [req]
                                                                (req.yield)
                                                                (ok-response req))})
                                    seen []]
                                (service.ask-async! {} QUESTIONS
                                                    (fn [answers]
                                                      (table.insert seen
                                                                    answers)))
                                (assert.are.equal 0 (length seen))
                                (tick!)
                                (assert.are.equal 1 (length ctx.calls))
                                (tick!)
                                (assert.are.equal 1 (length seen))
                                (assert.are.equal 0.99 (. seen 1 :a :noul))))))
                      (describe "consumer compatibility with openai backend"
                                (fn []
                                  (it "rate-tool-results works end-to-end with openai backend"
                                      (fn []
                                        (let [types (require :fen.core.types)
                                              read-out (.. "READ-HEAD "
                                                           (string.rep "r" 2000)
                                                           " READ-TAIL")
                                              span [(types.tool-result-message {:tool-call-id "tc1"
                                                                                :tool-name :read
                                                                                :content [(types.text-block read-out)]})]
                                              messages [(types.user-message "do this work")]
                                              service (fresh! {:settings {:backend "openai"}
                                                               :respond (fn [req]
                                                                          (assert.is_truthy (string.find req.url
                                                                                                         "api.openai.com"
                                                                                                         1
                                                                                                         true))
                                                                          {:status 200
                                                                           :body (json.encode {:model "gpt-6-luna"
                                                                                               :answers [{:type "predicate"
                                                                                                          :name "r1"
                                                                                                          :probability 0.95}]})})})
                                              compaction (require :fen.extensions.decide.compaction)
                                              (out-span dropped) (compaction.rate-tool-results messages
                                                                                               span)]
                                          (assert.are.equal 1 dropped)
                                          (assert.are.equal 1
                                                            (length ctx.calls))
                                          (let [content (. out-span 1 :content
                                                           1 :text)]
                                            (assert.is_truthy (string.find content
                                                                           "tool result omitted"
                                                                           1
                                                                           true)))))))))))
