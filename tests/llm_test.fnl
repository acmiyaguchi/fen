;; Offline smoke test for core.llm.build-request shape.
;; Run with: fennel tests/llm_test.fnl  (from the project root, inside nix shell)

(local fennel (require :fennel))

;; Wire up loader so (require :core.llm) resolves to src/core/llm.fnl during
;; tests (we don't want to require `make build` first).
(set fennel.path (.. "./src/?.fnl;./src/?/init.fnl;" fennel.path))
(fennel.install)

(local llm (require :core.llm))

(fn assert-eq [a b msg]
  (when (not= a b)
    (error (.. "assertion failed: " msg
               " expected=" (tostring b) " got=" (tostring a)))))

(let [req (llm.build-request
            {:model :gpt-4o-mini
             :messages [{:role :user :content :hi}]
             :max-tokens 64})]
  (assert-eq req.model :gpt-4o-mini "model passthrough")
  (assert-eq req.max_tokens 64 "max_tokens snake_case")
  (assert-eq (length req.messages) 1 "messages length")
  (assert-eq req.tools nil "no tools => omit field"))

(let [req (llm.build-request
            {:model :gpt-4o-mini
             :messages []
             :tools [{:type :function
                      :function {:name :ls :description "list" :parameters {:type :object}}}]})]
  (assert-eq (length req.tools) 1 "tools length")
  (assert-eq req.tool_choice :auto "tool_choice set when tools present"))

(print "llm_test.fnl: ok")
