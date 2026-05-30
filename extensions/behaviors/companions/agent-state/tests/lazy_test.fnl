;; M3 (issue #167): agent_state must be lazy and cooperative. A narrow query
;; must not build expensive branches (extension introspection, model
;; resolution, diagnostics), and the tool's :execute must accept and call the
;; cooperative yield-fn the agent loop threads in.

(local tool (require :fen.extensions.agent_state.tool))
(local types (require :fen.core.types))

(fn first-text [r]
  (. (. r.content 1) :text))

;; Build a fake runtime api whose expensive calls increment counters, so a
;; test can assert which branches a query forced.
(fn make-spy-api []
  (let [calls {:introspect 0 :list 0 :list-errors 0 :error-log-path 0
               :models-list 0 :session-info 0}
        incr (fn [k] (tset calls k (+ (. calls k) 1)))
        api {:diagnostics {:error-log-path (fn [] (incr :error-log-path)
                                             "/nonexistent/fen/errors.jsonl")
                           :list-errors (fn [] (incr :list-errors) [])}
             :list (fn [_kind] (incr :list) [])
             :introspect {:collect (fn [_ _] (incr :introspect) {})}
             :session {:info (fn [] (incr :session-info) nil)
                       :active-backend (fn [] nil)}
             :models {:list (fn [_] (incr :models-list) [])
                      :resolve (fn [_q _avail] {:status :error})
                      :canonical-id (fn [_] "x")}}]
    (values api calls)))

(fn fake-agent []
  {:model "test-model"
   :provider-name :openai
   :system-prompt "system text"
   :max-tokens 123
   :thinking-status "reason:medium"
   :provider-options {}
   :messages [(types.user-message "hello")]
   :tools []})

(describe "agent_state laziness and cooperation"
  (fn []
    (it "a narrow query does not force expensive branches"
      (fn []
        (let [(api calls) (make-spy-api)
              yields [0]
              yield-fn (fn [] (tset yields 1 (+ (. yields 1) 1)))
              r (tool.execute {:query "(:get :model)"}
                              {:agent (fake-agent)} api yield-fn)]
          (assert.is_false r.is-error?)
          (assert.are.equal "\"test-model\"" (first-text r))
          ;; None of the heavy branches were touched.
          (assert.are.equal 0 (. calls :introspect)
                            "introspect.collect must not run for (:get :model)")
          (assert.are.equal 0 (. calls :models-list)
                            "model resolution must not run for (:get :model)")
          (assert.are.equal 0 (. calls :list-errors))
          (assert.are.equal 0 (. calls :session-info))
          ;; error-log-path is the only eager diagnostics touch (one call).
          (assert.are.equal 1 (. calls :error-log-path))
          ;; The cooperative yield-fn was forwarded and called.
          (assert.is_true (> (. yields 1) 0) "yield-fn was not called"))))

    (it "forwarding a query into :extensions forces introspection"
      (fn []
        (let [(api calls) (make-spy-api)
              r (tool.execute {:query "(:get :extensions :loaded)"}
                              {:agent (fake-agent)} api nil)]
          (assert.is_false r.is-error?)
          (assert.is_true (> (. calls :introspect) 0)
                          "(:get :extensions ...) must force introspect.collect")
          (assert.is_true (> (. calls :list) 0)))))

    (it "whole-root (:get) forces every branch and renders without leaking thunks"
      (fn []
        (let [(api calls) (make-spy-api)
              r (tool.execute {:query "(:get)"}
                              {:agent (fake-agent)} api nil)
              text (first-text r)]
          (assert.is_false r.is-error?)
          ;; force-all! ran: heavy branches were materialized...
          (assert.is_true (> (. calls :introspect) 0))
          (assert.is_true (> (. calls :models-list) 0))
          ;; ...and the result is valid JSON (no function/thunk leaked through).
          (assert.is_nil (string.find text "function" 1 true))
          (assert.is_truthy (string.find text "extensions" 1 true)))))

    (it "works with no yield-fn (blocking caller)"
      (fn []
        (let [(api _calls) (make-spy-api)
              r (tool.execute {:query "(:get :model)"}
                              {:agent (fake-agent)} api nil)]
          (assert.is_false r.is-error?)
          (assert.are.equal "\"test-model\"" (first-text r)))))))
