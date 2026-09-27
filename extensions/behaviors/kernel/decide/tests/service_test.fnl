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

(local OK-BODY
  (json.encode
    {:model "typesafe/jev-1.13-20260917"
     :answers {:a {:type :noul :noul 0.99}
               :b {:type :choice :choice :follow-up
                   :probabilities {:cancel 0 :correction 0 :follow-up 1}
                   :confidence 0.99}}
     :usage {:input_tokens 447 :output_tokens 59 :cost 0.000018774}}))

(fn ok-response [_opts]
  {:status 200 :body OK-BODY :headers {}})

(fn clear-modules! []
  (tset package.loaded :fen.extensions.decide nil)
  (tset package.loaded :fen.extensions.decide.service nil)
  (tset package.loaded :fen.extensions.decide.jev nil))

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
             :api-key (or opts.key "sk-test")}))
    (let [api (test-api.make-runtime-api :decide manifest)
          decide (require :fen.extensions.decide)]
      (set api.settings {:extension (fn [] ctx.settings)})
      (set api.log (fn [level msg] (table.insert ctx.logs {: level : msg})))
      (decide.register api)
      (require :fen.extensions.decide.service))))

(fn logged? [needle]
  (accumulate [found? false _ rec (ipairs ctx.logs)]
    (or found? (and (= (type rec.msg) :string)
                    (not= nil (string.find rec.msg needle 1 true))))))

(fn tick! []
  (events.emit {:type :runtime-tick :busy? false}))

(describe "fen.extensions.decide.service"
  (fn []
    (after_each
      (fn []
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
        (let [service (fresh! {:settings {:model "custom/jev" :timeoutMs 1500}})]
          (service.ask {:task "x" :items [1 2]} QUESTIONS)
          (assert.are.equal 1 (length ctx.calls))
          (let [req (. ctx.calls 1)
                body (json.decode req.body)]
            (assert.are.equal :POST req.method)
            (assert.are.equal "https://openrouter.ai/api/alpha/decisions" req.url)
            (assert.are.equal "Bearer sk-test" req.headers.authorization)
            (assert.are.equal "application/json" (. req.headers :content-type))
            (assert.are.equal 1500 (. req :timeout-ms))
            (assert.are.equal 1500 (. req :connect-timeout-ms))
            (assert.are.equal "custom/jev" body.model)
            (assert.are.equal "x" body.state.task)
            (assert.are.equal :noul body.questions.a.type)
            (assert.are.equal "Work remains." (. body.questions.a.criteria :false))
            (assert.are.equal :choice body.questions.b.type)
            (assert.are.equal "Queue new work." (. body.questions.b.criteria :follow-up))))))

    (it "defaults the model and a short timeout with a capped connect timeout"
      (fn []
        (let [service (fresh! {:settings {:timeoutMs "fast"}})]
          (service.ask {} QUESTIONS)
          (let [req (. ctx.calls 1)]
            (assert.are.equal "~typesafe/jev-latest" (. (json.decode req.body) :model))
            (assert.are.equal 3000 (. req :timeout-ms))
            (assert.are.equal 2000 (. req :connect-timeout-ms))))))

    (it "resolves the key from the openrouter provider's api-key-var"
      (fn []
        (let [service (fresh! {:key false})
              path (require :fen.util.path)
              original-getenv path.getenv]
          (tset ext-state.providers :openrouter {:api-key-var :FEN_TEST_DECIDE_KEY})
          (set path.getenv (fn [name]
                             (if (= name :FEN_TEST_DECIDE_KEY) "sk-env" (original-getenv name))))
          (let [(ok? answers) (pcall service.ask {} QUESTIONS)]
            (set path.getenv original-getenv)
            (assert.is_true ok? answers)
            (assert.is_table answers)
            (assert.are.equal "Bearer sk-env" (. ctx.calls 1 :headers :authorization))))))

    (it "returns nil without a request when the extension is disabled"
      (fn []
        (let [service (fresh!)
              seen []]
          (tset ext-state.extensions :decide {:status :disabled})
          (assert.is_false (service.enabled?))
          (assert.is_nil (service.ask {} QUESTIONS))
          (service.ask-async! {} QUESTIONS (fn [answers] (table.insert seen {: answers})))
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
                               {:a {:type :score :instructions "?" :criteria criteria}}
                               {:a {:type :noul :instructions "" :criteria criteria}}
                               {:a {:type :noul :instructions "?" :criteria {:true "yes"}}}
                               {:a {:type :choice :instructions "?" :criteria {}}}
                               [{:type :noul :instructions "?" :criteria criteria}]])]
            (assert.is_nil (service.ask {} qs)))
          (assert.are.equal 0 (length ctx.calls))
          (assert.is_true (logged? "invalid questions")))))

    (it "skips requests over the size guard"
      (fn []
        (let [service (fresh!)
              big {:blob (string.rep "x" (+ service.max-request-bytes 1))}]
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
        (each [_ c (ipairs
                        [{:resp {:error "Timeout was reached" :curl-code 28} :log "Timeout"}
                         {:resp {:status 400
                                 :body "{\"error\":{\"message\":\"max_tokens_exceeded\",\"code\":400}}"}
                          :log "HTTP 400: max_tokens_exceeded"}
                         {:resp {:status 502 :body "<html>bad gateway</html>"} :log "HTTP 502"}
                         {:resp {:status 200 :body "not json"} :log "malformed response"}
                         {:resp {:status 200 :body "{\"answers\":{\"a\":{\"type\":\"noul\",\"noul\":0.5}}}"}
                          :log "missing or malformed answer: b"}
                         {:resp {:status 200
                                 :body "{\"answers\":{\"a\":{\"noul\":0.5},\"b\":{\"choice\":\"other\"}}}"}
                          :log "missing or malformed answer: b"}])]
          (let [service (fresh! {:respond (fn [_] c.resp)})]
            (assert.is_nil (service.ask {} QUESTIONS))
            (assert.are.equal 1 (length ctx.calls))
            (assert.is_true (logged? c.log) c.log)))))

    (it "maps a raising transport to nil"
      (fn []
        (let [service (fresh! {:respond (fn [_] (error "fen_http missing"))})]
          (assert.is_nil (service.ask {} QUESTIONS))
          (assert.is_true (logged? "fen_http missing")))))

    (it "passes a yield function through and propagates its errors"
      (fn []
        (let [yields {:n 0}
              service (fresh! {:respond (fn [req]
                                          (req.yield)
                                          (ok-response req))})]
          (assert.is_table (service.ask {} QUESTIONS
                                        {:yield (fn [] (set yields.n (+ yields.n 1)))}))
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
                                             (fn [answers] (table.insert seen answers))))
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

    (it "ask-async! reports nil once when the decision fails"
      (fn []
        (let [service (fresh! {:respond (fn [_] {:status 500 :body ""})})
              seen []]
          (service.ask-async! {} QUESTIONS
                              (fn [answers] (table.insert seen {: answers})))
          (tick!)
          (tick!)
          (assert.are.equal 1 (length seen))
          (assert.is_nil (. seen 1 :answers)))))))
