;; Tests for core.extensions.test_api — the test-side wrapper around core.extensions.
;; The contract is parity with production (`api.list` shapes match) plus
;; capture/fire affordances for asserting on what an extension did.

(local test-api (require :core.extensions.test_api))
(local extensions (require :core.extensions))

(describe "core.extensions.test_api"
  (fn []
    (it "make() resets the global extensions registry"
      (fn []
        (let [api1 (test-api.make :first)]
          (api1.register :tool {:name :leak :execute (fn [] {})})
          (assert.are.equal 1 (length (api1.list :tools))))
        (let [api2 (test-api.make :second)]
          (assert.are.equal 0 (length (api2.list :tools))))))

    (it "captures register :tool calls"
      (fn []
        (let [api (test-api.make)
              spec {:name :greet :execute (fn [] {})}]
          (api.register :tool spec)
          (assert.are.equal 1 (length api.captured.tools))
          (assert.are.equal :tool (. api.captured.tools 1 :kind))
          (assert.are.equal spec (. api.captured.tools 1 :spec)))))

    (it "captures prompt calls"
      (fn []
        (let [api (test-api.make)]
          (api.prompt "hello" {:order 10 :id :hello})
          (assert.are.equal 1 (length api.captured.prompts))
          (assert.are.equal "hello" (. api.captured.prompts 1 :text-or-fn))
          (assert.are.equal 10 (. api.captured.prompts 1 :opts :order))
          (assert.are.equal :hello (. api.captured.prompts 1 :opts :id)))))

    (it "captures emit calls in events-out and dispatches them"
      (fn []
        (let [api (test-api.make)
              seen []]
          (api.on :tool-call (fn [ev] (table.insert seen ev.name)))
          (api.emit {:type :tool-call :name :bash :id "1"})
          (assert.are.equal 1 (length api.captured.events-out))
          (assert.are.equal :bash (. api.captured.events-out 1 :name))
          (assert.are.same [:bash] seen))))

    (it "fire ev records to events-in and dispatches"
      (fn []
        (let [api (test-api.make)
              seen []]
          (api.on :tool-call (fn [ev] (table.insert seen ev.id)))
          (api.fire {:type :tool-call :name :bash :id "abc"})
          (assert.are.equal 1 (length api.captured.events-in))
          (assert.are.equal "abc" (. api.captured.events-in 1 :id))
          (assert.are.same ["abc"] seen))))

    (it "list parity: production and test apis report the same shape"
      (fn []
        (let [api (test-api.make :owner-x)]
          (api.register :tool {:name :greet :execute (fn [] {})})
          ;; api.list comes from production extensions.list — assert the
          ;; test wrapper does not interpose its own format.
          (let [from-test (api.list :tools)
                from-prod (extensions.list :tools)]
            (assert.are.equal (length from-prod) (length from-test))
            (assert.are.equal (. from-prod 1 :name) (. from-test 1 :name))
            (assert.are.equal (. from-prod 1 :owner) (. from-test 1 :owner))))))))
