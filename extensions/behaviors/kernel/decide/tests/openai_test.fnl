(local json (require :fen.util.json))
(local openai (require :fen.extensions.decide.openai))

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

(describe "fen.extensions.decide.openai"
          (fn []
            (describe "encode-request"
                      (fn []
                        (it "maps noul to predicate with criteria in instructions"
                            (fn []
                              (let [encoded (openai.encode-request "gpt-6-luna"
                                                                   {:task "x"}
                                                                   QUESTIONS)
                                    req (json.decode encoded)]
                                (assert.are.equal "gpt-6-luna" req.model)
                                (assert.are.equal (json.encode {:task "x"})
                                                  req.input)
                                (assert.are.equal 2 (length req.questions))
                                ;; Sorted by name: "a" first, "b" second
                                (let [qa (. req.questions 1)
                                      qb (. req.questions 2)]
                                  (assert.are.equal "predicate" qa.type)
                                  (assert.are.equal "a" qa.name)
                                  (assert.is_truthy (string.find qa.instructions
                                                                 "Is the task finished?"
                                                                 1 true))
                                  (assert.is_truthy (string.find qa.instructions
                                                                 "True if: The task is finished."
                                                                 1 true))
                                  (assert.is_truthy (string.find qa.instructions
                                                                 "False if: Work remains."
                                                                 1 true))
                                  (assert.are.equal "choice" qb.type)
                                  (assert.are.equal "b" qb.name)
                                  (assert.are.equal "Classify the input."
                                                    qb.instructions)
                                  ;; Choices are sorted by value: cancel, correction, follow-up
                                  (assert.are.equal 3 (length qb.choices))
                                  (assert.are.same {:value "cancel"
                                                    :description "Stop the current work."}
                                                   (. qb.choices 1))
                                  (assert.are.same {:value "correction"
                                                    :description "Fix the current work."}
                                                   (. qb.choices 2))
                                  (assert.are.same {:value "follow-up"
                                                    :description "Queue new work."}
                                                   (. qb.choices 3))))))
                        (it "passes string state directly without re-encoding"
                            (fn []
                              (let [encoded (openai.encode-request "gpt-6-luna"
                                                                   "raw prompt"
                                                                   QUESTIONS)
                                    req (json.decode encoded)]
                                (assert.are.equal "raw prompt" req.input))))
                        (it "handles empty state"
                            (fn []
                              (let [encoded (openai.encode-request "gpt-6-luna"
                                                                   nil QUESTIONS)
                                    req (json.decode encoded)]
                                (assert.are.equal "" req.input))))
                        (it "raises on unsupported question types"
                            (fn []
                              (let [bad-qs {:a {:type :score
                                                :instructions "score this"
                                                :criteria {:1 "low" :2 "high"}}}]
                                (assert.has_error (fn []
                                                    (openai.encode-request "gpt-6-luna"
                                                                           {}
                                                                           bad-qs))))))))
            (describe "post"
                      (fn []
                        (it "sends POST to OpenAI Decisions endpoint with auth and timeout"
                            (fn []
                              (let [original-http (. package.loaded
                                                     :fen.util.http)
                                    captured []]
                                (tset package.loaded :fen.util.http
                                      {:request (fn [req]
                                                  (table.insert captured req)
                                                  {:status 200
                                                   :body OK-BODY
                                                   :headers {}})})
                                (tset package.loaded
                                      :fen.extensions.decide.openai nil)
                                (let [openai-mod (require :fen.extensions.decide.openai)
                                      resp (openai-mod.post "{}"
                                                            "sk-openai-test"
                                                            3000 nil)]
                                  (tset package.loaded :fen.util.http
                                        original-http)
                                  (tset package.loaded
                                        :fen.extensions.decide.openai nil)
                                  (assert.are.equal 200 resp.status)
                                  (assert.are.equal 1 (length captured))
                                  (let [req (. captured 1)]
                                    (assert.are.equal :POST req.method)
                                    (assert.are.equal "https://api.openai.com/v1/decisions"
                                                      req.url)
                                    (assert.are.equal "Bearer sk-openai-test"
                                                      req.headers.authorization)
                                    (assert.are.equal "application/json"
                                                      req.headers.content-type)
                                    (assert.are.equal 3000 req.timeout-ms)
                                    (assert.are.equal 2000
                                                      req.connect-timeout-ms))))))))
            (describe "parse-response"
                      (fn []
                        (it "maps predicate and choice answers into normalized Fennel shapes"
                            (fn []
                              (let [resp {:status 200
                                          :body OK-BODY
                                          :headers {}}
                                    (answers usage) (openai.parse-response resp
                                                                           QUESTIONS)]
                                (assert.is_table answers)
                                (assert.are.same {:type :noul :noul 0.99}
                                                 answers.a)
                                (assert.are.equal :choice answers.b.type)
                                (assert.are.equal "follow-up" answers.b.choice)
                                (assert.are.equal 0.99 answers.b.confidence)
                                (assert.are.same {:cancel 0
                                                  :correction 0
                                                  :follow-up 1}
                                                 answers.b.probabilities)
                                (assert.are.equal 320 usage.input_tokens))))
                        (it "preserves nil confidence without inventing confidence"
                            (fn []
                              (let [body (json.encode {:answers [{:type "predicate"
                                                                  :name "a"
                                                                  :probability 0.5}
                                                                 {:type "choice"
                                                                  :name "b"
                                                                  :choice "cancel"
                                                                  :probabilities [{:value "cancel"
                                                                                   :probability 0.8}
                                                                                  {:value "correction"
                                                                                   :probability 0.1}
                                                                                  {:value "follow-up"
                                                                                   :probability 0.1}]}]})
                                    resp {:status 200 :body body :headers {}}
                                    (answers _) (openai.parse-response resp
                                                                       QUESTIONS)]
                                (assert.is_table answers)
                                (assert.is_nil answers.b.confidence)
                                (assert.are.equal "cancel" answers.b.choice))))
                        (it "handles refusals explicitly"
                            (fn []
                              (let [body (json.encode {:answers [{:type "refusal"
                                                                  :name "a"
                                                                  :refusal "Content violated policy"}]})
                                    resp {:status 200 :body body :headers {}}
                                    (answers reason) (openai.parse-response resp
                                                                            QUESTIONS)]
                                (assert.is_nil answers)
                                (assert.is_truthy (string.find reason
                                                               "refusal for a" 1
                                                               true)))))
                        (it "detects duplicate answers"
                            (fn []
                              (let [body (json.encode {:answers [{:type "predicate"
                                                                  :name "a"
                                                                  :probability 0.5}
                                                                 {:type "predicate"
                                                                  :name "a"
                                                                  :probability 0.7}
                                                                 {:type "choice"
                                                                  :name "b"
                                                                  :choice "cancel"
                                                                  :probabilities [{:value "cancel"
                                                                                   :probability 1}]}]})
                                    resp {:status 200 :body body :headers {}}
                                    (answers reason) (openai.parse-response resp
                                                                            QUESTIONS)]
                                (assert.is_nil answers)
                                (assert.is_truthy (string.find reason
                                                               "duplicate answer for a"
                                                               1 true)))))
                        (it "detects unexpected answers not in questions"
                            (fn []
                              (let [body (json.encode {:answers [{:type "predicate"
                                                                  :name "unknown_question"
                                                                  :probability 0.5}]})
                                    resp {:status 200 :body body :headers {}}
                                    (answers reason) (openai.parse-response resp
                                                                            QUESTIONS)]
                                (assert.is_nil answers)
                                (assert.is_truthy (string.find reason
                                                               "unexpected answer for unknown_question"
                                                               1 true)))))
                        (it "detects missing answers"
                            (fn []
                              (let [body (json.encode {:answers [{:type "predicate"
                                                                  :name "a"
                                                                  :probability 0.5}]})
                                    resp {:status 200 :body body :headers {}}
                                    (answers reason) (openai.parse-response resp
                                                                            QUESTIONS)]
                                (assert.is_nil answers)
                                (assert.is_truthy (string.find reason
                                                               "missing or malformed answer: b"
                                                               1 true)))))
                        (it "handles malformed probability, choice, or confidence"
                            (fn []
                              (let [make-body (fn [a-prob
                                                   b-choice
                                                   b-probs
                                                   b-conf]
                                                (json.encode {:answers [{:type "predicate"
                                                                         :name "a"
                                                                         :probability a-prob}
                                                                        {:type "choice"
                                                                         :name "b"
                                                                         :choice b-choice
                                                                         :probabilities b-probs
                                                                         :confidence b-conf}]}))]
                                ;; a out-of-range probability
                                (let [resp {:status 200
                                            :body (make-body 1.5 "cancel"
                                                             [{:value "cancel"
                                                               :probability 1}]
                                                             0.9)}
                                      (answers _) (openai.parse-response resp
                                                                         QUESTIONS)]
                                  (assert.is_nil answers))
                                ;; b choice not in criteria
                                (let [resp {:status 200
                                            :body (make-body 0.5 "other"
                                                             [{:value "cancel"
                                                               :probability 1}]
                                                             0.9)}
                                      (answers _) (openai.parse-response resp
                                                                         QUESTIONS)]
                                  (assert.is_nil answers))
                                ;; b confidence out of range
                                (let [resp {:status 200
                                            :body (make-body 0.5 "cancel"
                                                             [{:value "cancel"
                                                               :probability 1}]
                                                             1.5)}
                                      (answers _) (openai.parse-response resp
                                                                         QUESTIONS)]
                                  (assert.is_nil answers))
                                ;; b probabilities contains invalid value
                                (let [resp {:status 200
                                            :body (make-body 0.5 "cancel"
                                                             [{:value "invalid"
                                                               :probability 1}]
                                                             0.9)}
                                      (answers _) (openai.parse-response resp
                                                                         QUESTIONS)]
                                  (assert.is_nil answers)))))
                        (it "handles HTTP error responses"
                            (fn []
                              (let [resp {:status 400
                                          :body (json.encode {:error {:message "Invalid model specified"
                                                                      :type "invalid_request_error"}})}
                                    (answers reason) (openai.parse-response resp
                                                                            QUESTIONS)]
                                (assert.is_nil answers)
                                (assert.is_truthy (string.find reason
                                                               "HTTP 400: Invalid model specified"
                                                               1 true)))))
                        (it "handles transport failure and nil response"
                            (fn []
                              (let [(a1 r1) (openai.parse-response nil
                                                                   QUESTIONS)
                                    (a2 r2) (openai.parse-response {:error "network down"}
                                                                   QUESTIONS)]
                                (assert.is_nil a1)
                                (assert.are.equal "no response" r1)
                                (assert.is_nil a2)
                                (assert.is_truthy (string.find r2
                                                               "transport: network down"
                                                               1 true)))))))))
