;; Input-time decide questions through the input-handler pipeline with a
;; mocked decide service: the idle topic-shift hint (#513) and busy-line
;; classification with /decide undo (#514).

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local input-pipeline (require :fen.core.extensions.input))
(local input-registry (require :fen.core.extensions.register.input))
(local command-registry (require :fen.core.extensions.register.command))
(local types (require :fen.core.types))
(local steering (require :fen.extensions.steering.service))
(local steering-state (require :fen.extensions.steering.state))
(local steering-ext (require :fen.extensions.steering))
(local store (require :fen.extensions.decide.state))

(local original-service (. package.loaded :fen.extensions.decide.service))
(local original-input (. package.loaded :fen.extensions.decide.input))

(var asks [])

(fn mock-service [?opts]
  "Decide stub that records ask-async! calls; tests answer them by hand to
   control when (and in what order) the callbacks land."
  (let [opts (or ?opts {})]
    {:enabled? (fn [] (not= opts.enabled? false))
     :ask-async! (or opts.ask-async!
                     (fn [st questions on-done]
                       (table.insert asks {:state st : questions : on-done})))
     :finish-pending! (fn [] nil)
     :pump! (fn [] nil)}))

(fn fresh! [?opts]
  "Register decide (and steering unless opts.steering? is false) over a mocked
   service; returns the events seen from now on."
  (let [opts (or ?opts {})]
    (test-api.reset!)
    (steering.clear-queues!)
    (set asks [])
    (set store.topic-pending nil)
    (set store.reclassified nil)
    (tset package.loaded :fen.extensions.decide.service (mock-service opts))
    (tset package.loaded :fen.extensions.decide nil)
    (tset package.loaded :fen.extensions.decide.input nil)
    (let [decide (require :fen.extensions.decide)]
      (decide.register (test-api.make-runtime-api :decide)))
    (when (not= opts.steering? false)
      (steering-ext.register (test-api.make-runtime-api :steering)))
    (let [seen []]
      (events.on :* (fn [ev] (table.insert seen ev)) :decide-input-test)
      seen)))

(fn restore-modules! []
  (tset package.loaded :fen.extensions.decide.service original-service)
  (tset package.loaded :fen.extensions.decide nil)
  (tset package.loaded :fen.extensions.decide.input original-input)
  (steering.clear-queues!)
  (test-api.reset!))

(fn of-type [seen t]
  (icollect [_ ev (ipairs seen)] (when (= ev.type t) ev)))

(fn asks-for [id]
  (icollect [_ a (ipairs asks)] (when (. a.questions id) a)))

;; ---------------------------------------------------------------------------
;; Topic shift (idle prompts)
;; ---------------------------------------------------------------------------

(fn history [n-prompts]
  (let [msgs []]
    (for [i 1 n-prompts]
      (table.insert msgs (types.user-message (.. "fix the parser bug part " i)))
      (table.insert msgs (types.assistant-message
                           {:api :test :provider :test :model "m"
                            :content [(types.text-block (.. "patched parser step " i))]
                            :stop-reason :stop})))
    msgs))

(fn submit [text ?opts]
  (let [opts (or ?opts {})]
    (input-pipeline.handle {:kind :user-input :text text}
                           {:busy? (not (not opts.busy?))
                            :state {:agent {:messages (or opts.messages (history 2))}}})))

(fn answer-shift! [call p]
  (call.on-done (when p {:topic_shift {:type :noul :noul p}})))

(describe "decide topic-shift hint"
  (fn []
    (after_each restore-modules!)

    (it "registers one observing input handler before the steering fallback"
      (fn []
        (fresh! {:steering? false})
        (let [lst (input-registry.list)]
          (assert.are.equal 1 (length lst))
          (assert.are.equal :decide (. lst 1 :name))
          (assert.are.equal 900 (. lst 1 :order)))))

    (it "suggests /handoff through a :hint event when a shift is likely"
      (fn []
        (let [seen (fresh! {:steering? false})
              action (submit "what's a good sourdough starter ratio?")]
          ;; The prompt is never held or changed while decide runs.
          (assert.are.equal :continue action.action)
          (assert.are.equal "what's a good sourdough starter ratio?" action.input.text)
          (assert.are.equal 1 (length asks))
          (let [st (. asks 1 :state)]
            (assert.are.equal "what's a good sourdough starter ratio?" st.new_message)
            (assert.are.same [{:role :user :text "fix the parser bug part 1"}
                              {:role :assistant :text "patched parser step 1"}
                              {:role :user :text "fix the parser bug part 2"}
                              {:role :assistant :text "patched parser step 2"}]
                             st.recent)
            (assert.are.equal :noul (. asks 1 :questions :topic_shift :type)))
          (assert.are.equal 0 (length (of-type seen :hint)))
          (answer-shift! (. asks 1) 0.9)
          (let [hints (of-type seen :hint)]
            (assert.are.equal 1 (length hints))
            (assert.are.equal "topic changed · /handoff" (. hints 1 :text))
            (assert.are.equal "handoff/topic-shift:what's a good sourdough starter ratio?"
                              (. hints 1 :key))))))

    (it "starts the turn with the prompt unchanged when steering follows"
      (fn []
        (fresh!)
        (let [action (submit "a whole new topic")]
          (assert.are.equal :start action.action)
          (assert.are.equal "a whole new topic" action.text)
          (assert.are.equal 1 (length (asks-for :topic_shift))))))

    (it "stays quiet below the threshold or when decide has no answer"
      (fn []
        (let [seen (fresh! {:steering? false})]
          (submit "keep going on the parser")
          (answer-shift! (. asks 1) 0.84)
          (submit "and the lexer too")
          (answer-shift! (. asks 2) nil)
          (assert.are.equal 2 (length asks))
          (assert.are.equal 0 (length (of-type seen :hint))))))

    (it "asks nothing while decide is disabled"
      (fn []
        (let [seen (fresh! {:enabled? false :steering? false})
              action (submit "something else entirely")]
          (assert.are.equal :continue action.action)
          (assert.are.equal 0 (length asks))
          (assert.are.equal 0 (length (of-type seen :hint))))))

    (it "skips the question without two earlier prompts or while a turn is running"
      (fn []
        (fresh! {:steering? false})
        (submit "new topic" {:messages (history 1)})
        (submit "new topic" {:busy? true})
        (assert.are.equal 0 (length (asks-for :topic_shift)))))

    (it "drops a late answer once another message was submitted"
      (fn []
        (let [seen (fresh! {:steering? false})
              emit (. (test-api.make-runtime-api :probe) :emit)]
          (submit "first new topic")
          (submit "second new topic")
          (answer-shift! (. asks 1) 0.99)
          (assert.are.equal 0 (length (of-type seen :hint)))
          (answer-shift! (. asks 2) 0.99)
          (assert.are.equal 1 (length (of-type seen :hint)))
          ;; A slash command is a :user line too, and a reset starts over.
          (submit "third new topic")
          (emit {:type :user :text "/model"})
          (answer-shift! (. asks 3) 0.99)
          (submit "fourth new topic")
          (emit {:type :reset-conversation})
          (answer-shift! (. asks 4) 0.99)
          (assert.are.equal 1 (length (of-type seen :hint))))))))

;; ---------------------------------------------------------------------------
;; Busy-line classification and /decide undo
;; ---------------------------------------------------------------------------

(fn route [choice confidence]
  {:route {:type :choice : choice :confidence confidence
           :probabilities {choice confidence}}})

(fn runtime []
  {:busy? true
   :turn-id 1
   :agent {:messages [(types.user-message "refactor the parser")
                      (types.assistant-message
                        {:content [(types.tool-call-block :c1 :bash {:command "make test"})]})]}})

(fn submit! [line rt]
  (input-pipeline.handle {:kind :user-input :text line} {:busy? rt.busy? :state rt}))

(fn undo! []
  (command-registry.dispatch "/decide undo" (runtime)))

(describe "decide busy-line classification"
  (fn []
    (after_each restore-modules!)

    (it "queues the line as steering before any answer and asks one choice question"
      (fn []
        (fresh!)
        (let [rt (runtime)
              result (submit! "also update the docs" rt)]
          (assert.are.equal :queued result.action)
          (assert.are.equal :steering result.queue)
          (assert.are.same ["also update the docs"] steering-state.steering-queue)
          (assert.are.equal 1 (length asks))
          (let [{:state st : questions} (. asks 1)]
            (assert.are.equal "also update the docs" st.message)
            (assert.are.equal "refactor the parser" st.latest_user_message)
            (assert.are.equal "running tools: bash" st.activity)
            (assert.are.equal :choice questions.route.type)
            (assert.is_truthy (. questions.route.criteria :follow-up))
            (assert.is_truthy questions.route.criteria.correction)
            (assert.is_truthy questions.route.criteria.cancel)))))

    (it "moves a confident follow-up still pending in steering to the follow-up queue"
      (fn []
        (let [seen (fresh!)
              rt (runtime)]
          (submit! "then write a changelog entry" rt)
          ((. asks 1 :on-done) (route :follow-up 0.9))
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
            (assert.is_truthy (string.find (. infos (length infos) :text) "/decide undo" 1 true))))))

    (it "leaves a line the agent already drained untouched"
      (fn []
        (let [seen (fresh!)
              rt (runtime)]
          (submit! "then write a changelog entry" rt)
          (assert.are.same ["then write a changelog entry"] (steering.get-steering))
          ((. asks 1 :on-done) (route :follow-up 0.95))
          (assert.are.same [] steering-state.follow-up-queue)
          (assert.are.equal 0 (length (of-type seen :info)))
          (assert.is_nil store.reclassified))))

    (it "keeps a correction in steering without a notice"
      (fn []
        (let [seen (fresh!)
              rt (runtime)]
          (submit! "no, use the other parser" rt)
          ((. asks 1 :on-done) (route :correction 0.99))
          (assert.are.same ["no, use the other parser"] steering-state.steering-queue)
          (assert.are.equal 0 (length (of-type seen :info))))))

    (it "suggests the cancel key for a cancel request but never cancels"
      (fn []
        (let [seen (fresh!)
              rt (runtime)]
          (submit! "stop, never mind" rt)
          ((. asks 1 :on-done) (route :cancel 0.97))
          (assert.is_nil rt.cancel-requested?)
          (assert.is_true rt.busy?)
          (assert.are.same ["stop, never mind"] steering-state.steering-queue)
          (assert.are.equal 0 (length (of-type seen :cancelled)))
          (let [infos (of-type seen :info)]
            (assert.are.equal 1 (length infos))
            (assert.is_truthy (string.find (. infos 1 :text) "ctrl-c" 1 true))))))

    (it "keeps today's routing on low confidence, a nil answer, or an idle runtime"
      (fn []
        (let [seen (fresh!)
              rt (runtime)]
          (submit! "maybe later" rt)
          ((. asks 1 :on-done) (route :follow-up 0.5))
          (submit! "and this" rt)
          ((. asks 2 :on-done) nil)
          (submit! "and that" rt)
          (set rt.busy? false)
          ((. asks 3 :on-done) (route :follow-up 0.99))
          (assert.are.same ["maybe later" "and this" "and that"] steering-state.steering-queue)
          (assert.are.same [] steering-state.follow-up-queue)
          (assert.are.equal 0 (length (of-type seen :info))))))

    (it "ignores a decision that arrives after its turn ended, even while a new turn runs"
      (fn []
        (let [seen (fresh!)
              rt (runtime)]
          (submit! "then write a changelog entry" rt)
          (set rt.turn-id 2)
          ((. asks 1 :on-done) (route :follow-up 0.99))
          (submit! "stop now" rt)
          (set rt.turn-id 3)
          ((. asks 2 :on-done) (route :cancel 0.99))
          (assert.are.same ["then write a changelog entry" "stop now"]
                           steering-state.steering-queue)
          (assert.are.same [] steering-state.follow-up-queue)
          (assert.are.equal 0 (length (of-type seen :info))))))

    (it "caps the latest user message it sends without concatenating every block"
      (fn []
        (fresh!)
        (let [big (string.rep "x" 50000)
              blocks (fcollect [_ 1 200] (types.text-block big))
              rt {:busy? true :turn-id 1
                  :agent {:messages [(types.user-message "older request")
                                     (types.user-message blocks)
                                     (types.assistant-message {:content []})]}}]
          (submit! (string.rep "y" 10000) rt)
          (let [st (. asks 1 :state)]
            (assert.are.equal 2000 (length st.latest_user_message))
            (assert.are.equal (string.rep "x" 2000) st.latest_user_message)
            (assert.are.equal 2000 (length st.message))
            (assert.are.equal "generating a response" st.activity)))
        (let [rt {:busy? true :turn-id 1
                  :agent {:messages [(types.user-message
                                       [(types.text-block "first") (types.text-block "second")])]}}]
          (submit! "and more" rt)
          (assert.are.equal "first\nsecond" (. asks 2 :state :latest_user_message)))
        (let [calls (fcollect [i 1 5000]
                      {:type :tool-call :id (.. "c" i) :name (string.rep "t" 40) :arguments {}})
              rt {:busy? true :turn-id 1
                  :agent {:messages [(types.user-message "go")
                                     (types.assistant-message {:content calls})]}}]
          (submit! "and the activity" rt)
          (let [act (. asks 3 :state :activity)]
            (assert.is_truthy (string.find act "^running tools: t"))
            (assert.is_true (<= (length act) 2000))))))

    (it "does not classify when decide is disabled, for > follow-ups, slash text, or when idle"
      (fn []
        (fresh! {:enabled? false})
        (submit! "steer me" (runtime))
        (assert.are.equal 0 (length asks))
        (fresh!)
        (submit! "> after this" (runtime))
        (assert.are.same ["after this"] steering-state.follow-up-queue)
        ;; Never classify slash text, even if a caller routes it here literally.
        (submit! "/queue" (runtime))
        (let [idle (runtime)]
          (set idle.busy? false)
          (assert.are.equal :start (. (submit! "hello" idle) :action)))
        (assert.are.equal 0 (length (asks-for :route)))))

    (it "keeps the line queued once when the classifier raises"
      (fn []
        (fresh! {:ask-async! (fn [] (error "boom"))})
        (let [result (submit! "steer me" (runtime))]
          (assert.are.equal :queued result.action)
          (assert.are.same ["steer me"] steering-state.steering-queue))))

    (it "/decide undo moves the reclassified line back to steering once"
      (fn []
        (let [seen (fresh!)
              rt (runtime)]
          (submit! "then write a changelog entry" rt)
          ((. asks 1 :on-done) (route :follow-up 0.9))
          (undo!)
          (assert.are.same ["then write a changelog entry"] steering-state.steering-queue)
          (assert.are.same [] steering-state.follow-up-queue)
          (let [queued (of-type seen :queued)]
            (assert.are.equal :steering (. queued (length queued) :queue)))
          (assert.are.equal 0 (length (of-type seen :error)))
          (undo!)
          (let [infos (of-type seen :info)]
            (assert.are.equal "decide undo: nothing to undo" (. infos (length infos) :text))))))

    (it "clearing the follow-up queue invalidates the undo record"
      (fn []
        (fresh!)
        (let [rt (runtime)]
          (submit! "then write a changelog entry" rt)
          ((. asks 1 :on-done) (route :follow-up 0.9))
          ;; Clearing steering alone leaves the follow-up line and its undo.
          (steering.clear-queues! :steering)
          (assert.are.equal "then write a changelog entry" store.reclassified)
          ;; /cancel-all, /new, /resume, and /handoff clear both queues.
          (steering.clear-queues!)
          (assert.is_nil store.reclassified)
          ;; The same text queued again as a follow-up is not moved by a stale undo.
          (steering.queue! :follow-up "then write a changelog entry")
          (assert.are.equal "nothing to undo" (. ((. (require :fen.extensions.decide.input) :undo!)) :error))
          (assert.are.same ["then write a changelog entry"] steering-state.follow-up-queue))))))
