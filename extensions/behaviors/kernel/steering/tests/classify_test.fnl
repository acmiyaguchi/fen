;; Busy-line classification through the steering input handler with a mocked decide service.

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local input-pipeline (require :fen.core.extensions.input))
(local types (require :fen.core.types))
(local steering (require :fen.extensions.steering.service))
(local steering-state (require :fen.extensions.steering.state))
(local classify (require :fen.extensions.steering.classify))
(local steering-ext (require :fen.extensions.steering))

(local original-decide (. package.loaded :fen.extensions.decide.service))

(var asks [])

(fn install-decide! [enabled?]
  (set asks [])
  (tset package.loaded :fen.extensions.decide.service
        {:enabled? (fn [] enabled?)
         :ask-async! (fn [st questions on-done]
                       (table.insert asks {:state st : questions : on-done}))}))

(fn answer [choice confidence]
  {:route {:type :choice : choice :confidence confidence
           :probabilities {choice confidence}}})

(fn runtime []
  {:busy? true
   :agent {:messages [(types.user-message "refactor the parser")
                      (types.assistant-message
                        {:content [(types.tool-call-block :c1 :bash {:command "make test"})]})]}})

(fn submit! [line rt]
  (input-pipeline.handle {:kind :user-input :text line} {:busy? rt.busy? :state rt}))

(fn reset! []
  (test-api.reset!)
  (steering.clear-queues!)
  (steering-ext.register (test-api.make-runtime-api :steering))
  (install-decide! true))

(fn watch []
  (let [seen []]
    (events.on :* (fn [ev] (table.insert seen ev)) :classify-test)
    seen))

(fn of-type [seen t]
  (icollect [_ ev (ipairs seen)] (when (= ev.type t) ev)))

(describe "busy-line classification"
  (fn []
    (before_each reset!)
    (after_each
      (fn []
        (tset package.loaded :fen.extensions.decide.service original-decide)
        (steering.clear-queues!)
        (test-api.reset!)))

    (it "queues the line as steering before any answer and asks one choice question"
      (fn []
        (let [rt (runtime)
              result (submit! "also update the docs" rt)]
          (assert.are.equal :queued result.action)
          (assert.are.equal :steering result.queue)
          (assert.are.same ["also update the docs"] steering-state.steering-queue)
          (assert.are.equal 1 (length asks))
          (let [{:state st : questions} (. asks 1)]
            (assert.are.equal "also update the docs" st.message)
            (assert.are.equal "refactor the parser" st.current_request)
            (assert.are.equal "running tools: bash" st.activity)
            (assert.are.equal :choice questions.route.type)
            (assert.is_truthy (. questions.route.criteria :follow-up))
            (assert.is_truthy questions.route.criteria.correction)
            (assert.is_truthy questions.route.criteria.cancel)))))

    (it "moves a confident follow-up still pending in steering to the follow-up queue"
      (fn []
        (let [rt (runtime)
              seen (watch)]
          (submit! "then write a changelog entry" rt)
          ((. asks 1 :on-done) (answer :follow-up 0.9))
          (assert.are.same [] steering-state.steering-queue)
          (assert.are.same ["then write a changelog entry"] steering-state.follow-up-queue)
          (let [queued (of-type seen :queued)
                last (. queued (length queued))
                status (of-type seen :set-status-info)]
            (assert.are.equal :follow-up last.queue)
            (assert.are.equal "then write a changelog entry" last.text)
            (assert.are.equal 1 (. status (length status) :info :follow-up-queued))
            (assert.are.equal 0 (. status (length status) :info :steering-queued)))
          (let [infos (of-type seen :info)]
            (assert.is_truthy (string.find (. infos (length infos) :text) "/queue undo" 1 true))))))

    (it "leaves a line the agent already drained untouched"
      (fn []
        (let [rt (runtime)
              seen (watch)]
          (submit! "then write a changelog entry" rt)
          (assert.are.same ["then write a changelog entry"] (steering.get-steering))
          ((. asks 1 :on-done) (answer :follow-up 0.95))
          (assert.are.same [] steering-state.follow-up-queue)
          (assert.are.equal 0 (length (of-type seen :info)))
          (assert.is_false (. (classify.undo!) :ok)))))

    (it "keeps a correction in steering without a notice"
      (fn []
        (let [rt (runtime)
              seen (watch)]
          (submit! "no, use the other parser" rt)
          ((. asks 1 :on-done) (answer :correction 0.99))
          (assert.are.same ["no, use the other parser"] steering-state.steering-queue)
          (assert.are.equal 0 (length (of-type seen :info))))))

    (it "suggests the cancel key for a cancel request but never cancels"
      (fn []
        (let [rt (runtime)
              seen (watch)]
          (submit! "stop, never mind" rt)
          ((. asks 1 :on-done) (answer :cancel 0.97))
          (assert.is_nil rt.cancel-requested?)
          (assert.is_true rt.busy?)
          (assert.are.same ["stop, never mind"] steering-state.steering-queue)
          (assert.are.equal 0 (length (of-type seen :cancelled)))
          (let [infos (of-type seen :info)]
            (assert.are.equal 1 (length infos))
            (assert.is_truthy (string.find (. infos 1 :text) "ctrl-c" 1 true))))))

    (it "keeps today's routing on low confidence, a nil answer, or an idle runtime"
      (fn []
        (let [rt (runtime)
              seen (watch)]
          (submit! "maybe later" rt)
          ((. asks 1 :on-done) (answer :follow-up 0.5))
          (submit! "and this" rt)
          ((. asks 2 :on-done) nil)
          (submit! "and that" rt)
          (set rt.busy? false)
          ((. asks 3 :on-done) (answer :follow-up 0.99))
          (assert.are.same ["maybe later" "and this" "and that"] steering-state.steering-queue)
          (assert.are.same [] steering-state.follow-up-queue)
          (assert.are.equal 0 (length (of-type seen :info))))))

    (it "does not classify when decide is disabled, for > follow-ups, or when idle"
      (fn []
        (install-decide! false)
        (submit! "steer me" (runtime))
        (assert.are.equal 0 (length asks))
        (install-decide! true)
        (submit! "> after this" (runtime))
        (assert.are.same ["after this"] steering-state.follow-up-queue)
        (let [idle (runtime)]
          (set idle.busy? false)
          (assert.are.equal :start (. (submit! "hello" idle) :action)))
        (classify.observe! {:action :queued :queue :steering :text "/queue"} {:busy? true :state (runtime)})
        (assert.are.equal 0 (length asks))))

    (it "keeps the line queued once when the classifier raises"
      (fn []
        (tset package.loaded :fen.extensions.decide.service
              {:enabled? (fn [] true)
               :ask-async! (fn [] (error "boom"))})
        (let [result (submit! "steer me" (runtime))]
          (assert.are.equal :queued result.action)
          (assert.are.same ["steer me"] steering-state.steering-queue))))

    (it "undo moves the reclassified line back to steering once"
      (fn []
        (let [rt (runtime)
              seen (watch)]
          (submit! "then write a changelog entry" rt)
          ((. asks 1 :on-done) (answer :follow-up 0.9))
          (let [result (classify.undo!)]
            (assert.is_true result.ok)
            (assert.are.equal :steering result.queue))
          (assert.are.same ["then write a changelog entry"] steering-state.steering-queue)
          (assert.are.same [] steering-state.follow-up-queue)
          (let [queued (of-type seen :queued)]
            (assert.are.equal :steering (. queued (length queued) :queue)))
          (assert.are.equal "nothing to undo" (. (classify.undo!) :error)))))))

(describe "steering requeue!"
  (fn []
    (before_each (fn [] (test-api.reset!) (steering.clear-queues!)))

    (it "moves the most recent pending copy and rejects same-queue or missing moves"
      (fn []
        (steering.queue! :steering "a")
        (steering.queue! :steering "b")
        (steering.queue! :steering "a")
        (assert.is_true (. (steering.requeue! "a" :steering :follow-up) :ok))
        (assert.are.same ["a" "b"] steering-state.steering-queue)
        (assert.are.same ["a"] steering-state.follow-up-queue)
        (assert.is_false (. (steering.requeue! "b" :steering :steering) :ok))
        (assert.is_false (. (steering.requeue! "zzz" :steering :follow-up) :ok))
        (assert.are.same ["a" "b"] steering-state.steering-queue)))))
