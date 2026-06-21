;; Tests for the deterministic, scriptable mock provider.

(local mp (require :fen.extensions.provider_mock.mock_provider))
(local types (require :fen.core.types))

(fn ctx [messages]
  {:system-prompt "sys" :tools [] :messages (or messages [])})

(fn user [text] (types.user-message text))

(fn assistant [text]
  (types.assistant-message {:api :mock :provider :mock :model :mock
                            :content [(types.text-block text)]
                            :stop-reason :stop}))

(describe "provider_mock.spec->assistant"
  (fn []
    (it "treats a bare string as visible text with stop-reason :stop"
      (fn []
        (let [m (mp.spec->assistant "hello" :mock)]
          (assert.are.equal :assistant m.role)
          (assert.are.equal :stop m.stop-reason)
          (assert.are.equal "hello" (types.assistant-text m)))))

    (it "builds a tool call and defaults stop-reason to :tool-use"
      (fn []
        (let [m (mp.spec->assistant
                  {:tool-call {:id "c1" :name :read :args {:path "README.md"}}}
                  :mock)
              calls (types.assistant-tool-calls m)]
          (assert.are.equal :tool-use m.stop-reason)
          (assert.are.equal 1 (length calls))
          (assert.are.equal "c1" (. calls 1 :id))
          (assert.are.equal "read" (. calls 1 :name))
          (assert.are.equal "README.md" (. calls 1 :arguments :path)))))

    (it "supports parallel tool calls"
      (fn []
        (let [m (mp.spec->assistant
                  {:tool-calls [{:id "a" :name :noop} {:id "b" :name :noop}]}
                  :mock)]
          (assert.are.equal :tool-use m.stop-reason)
          (assert.are.equal 2 (length (types.assistant-tool-calls m))))))

    (it "emits thinking + text blocks"
      (fn []
        (let [m (mp.spec->assistant {:thinking "hmm" :text "answer"} :mock)]
          (assert.are.equal 2 (length m.content))
          (assert.are.equal "hmm" (. (types.assistant-thinking m) 1 :thinking))
          (assert.are.equal "answer" (types.assistant-text m)))))

    (it "maps :error to a stop-reason :error message"
      (fn []
        (let [m (mp.spec->assistant {:error "boom"} :mock)]
          (assert.are.equal :error m.stop-reason)
          (assert.are.equal "boom" m.error-message))))))

(describe "provider_mock.complete"
  (fn []
    (it "echoes the last user message when no script is configured"
      (fn []
        (let [m (mp.complete :mock (ctx [(user "ping")]) {})]
          (assert.are.equal "[mock] ping" (types.assistant-text m)))))

    (it "replays a sequence script one turn per assistant message"
      (fn []
        (let [script [{:tool-call {:id "c1" :name :read :args {:path "f"}}}
                      "all done"]
              opts {:mock-script script}
              ;; turn 1: no prior assistant messages -> first script entry
              m1 (mp.complete :mock (ctx [(user "go")]) opts)
              ;; turn 2: one prior assistant message -> second entry
              m2 (mp.complete :mock
                              (ctx [(user "go")
                                    (assistant "x")
                                    (types.tool-result-message
                                      {:tool-call-id "c1" :tool-name :read
                                       :content [(types.text-block "data")]})])
                              opts)]
          (assert.are.equal :tool-use m1.stop-reason)
          (assert.are.equal :stop m2.stop-reason)
          (assert.are.equal "all done" (types.assistant-text m2)))))

    (it "drives a function script with the request and turn index"
      (fn []
        (let [opts {:mock-script (fn [req]
                                   {:text (.. "turn " req.turn
                                              " saw " (length req.messages))})}
              m (mp.complete :mock (ctx [(user "a")]) opts)]
          (assert.are.equal "turn 1 saw 1" (types.assistant-text m)))))

    (it "returns an exhaustion turn past the end of a sequence script"
      (fn []
        (let [opts {:mock-script ["only"]}
              m (mp.complete :mock (ctx [(user "a") (assistant "only")]) opts)]
          (assert.are.equal "[mock] script exhausted" (types.assistant-text m)))))

    (it "synthesizes streaming events through emit-block-events"
      (fn []
        (let [events []
              on-event (fn [ev] (table.insert events ev.type))]
          (mp.complete :mock (ctx [(user "hi")]) {} on-event)
          (assert.are.equal :start (. events 1))
          (assert.are.equal :done (. events (length events))))))))
