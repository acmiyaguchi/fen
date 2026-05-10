;; Test-only extension for real-PTY TUI smoke scenarios.
;; Loaded explicitly by tests; not part of the default extension set.

(fn first-word [s]
  (or (string.match (or s "") "^%s*([^%s]+)") ""))

(fn emit-long [api n]
  (let [count (or (tonumber n) 80)]
    (for [i 1 count]
      (api.emit {:type :assistant-text
                 :text (string.format "smoke-row-%03d deterministic transcript fixture" i)}))
    (api.emit {:type :info
               :text (.. "smoke-emit long " (tostring count) " done")})))

(fn emit-tool [api]
  (api.emit {:type :tool-call
             :id "smoke-tool-1"
             :name "read"
             :arguments {:path "README.md"}})
  (api.emit {:type :tool-result
             :id "smoke-tool-1"
             :result {:content [{:type :text
                                  :text "smoke tool body line one\nsmoke tool body line two"}]}})
  (api.emit {:type :info :text "smoke-emit tool done"}))

(fn emit-markdown [api]
  (api.emit {:type :assistant-text
             :text "## smoke markdown heading\n\nsmoke markdown body"})
  (api.emit {:type :info :text "smoke-emit markdown done"}))

(fn emit-error [api]
  (api.emit {:type :error
             :error "smoke fixture error"
             :details "deterministic error from pty-driver"})
  (api.emit {:type :info :text "smoke-emit error done"}))

(fn run-select [api]
  (let [choice (api.ui.select
                 {:label "smoke select"
                  :choices [{:label "alpha" :value "a" :description "first option"}
                            {:label "beta" :value "b" :description "second option"}
                            {:label "gamma" :value "g" :description "third option"}]})]
    (api.emit {:type :info
               :text (if choice
                         (.. "smoke-select picked: " (tostring choice.label))
                         "smoke-select cancelled")})))

(fn handle [api args]
  (let [cmd (first-word args)]
    (if (= cmd "long")
        (emit-long api (string.match (or args "") "^%s*long%s+(%d+)"))
        (= cmd "tool")
        (emit-tool api)
        (= cmd "markdown")
        (emit-markdown api)
        (= cmd "error")
        (emit-error api)
        (api.emit {:type :info
                   :text "smoke-emit commands: long|tool|markdown|error"}))))

(fn register [api]
  (api.register :command
    {:name :smoke-emit
     :description "Emit deterministic PTY smoke transcript fixtures"
     :handler (fn [args _state] (handle api args))})
  (api.register :command
    {:name :smoke-select
     :description "Open a deterministic TUI select fixture"
     :handler (fn [_args _state] (run-select api))})
  true)

{:register register}
