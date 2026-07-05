(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local tools (require :fen.core.tools))
(local json (require :fen.util.json))

;; Mocks for the child-spawning collaborators. The process mock writes a blob
;; to the FEN_JSON_OUTPUT_PATH the tool passes via :env, then returns a result
;; record shaped like run-captured's.
(fn install-mocks [run-captured-fn find-agent-fn]
  (tset package.loaded :fen.util.process {:run-captured run-captured-fn})
  (tset package.loaded :fen.runtime {:binary-path (fn [] "/bin/true")})
  (tset package.loaded :fen.extensions.subagent.discover
        {:find-agent find-agent-fn :roots (fn [] [])}))

(fn fresh []
  (test-api.reset!)
  (tset package.loaded :fen.extensions.subagent nil)
  (let [subagent (require :fen.extensions.subagent)
        api (test-api.make-runtime-api :subagent)]
    (subagent.register api)
    subagent))

(fn registered-tool [name]
  (var found nil)
  (each [_ rec (ipairs (tool-registry.merged []))]
    (when (and (= found nil) (= rec.name name))
      (set found rec)))
  found)

(fn tool-registered? [name]
  (not (not (registered-tool name))))

(fn execute-tool [args]
  (let [reg (tool-registry.merged [])
        out (tools.execute-call reg
                                {:type :tool-call :id "call-1"
                                 :name :subagent :arguments args}
                                {})]
    out.result))

(fn first-text [content]
  (let [b (. content 1)]
    (if (and b (= b.type :text)) b.text "")))

(local scout-cfg {:name "scout" :description "Recon"
                  :model "claude-haiku-4-5" :provider nil
                  :timeout-seconds nil :body "You are a scout."})

(describe "subagent tool"
  (fn []
    (var saved {})
    (before_each
      (fn []
        (set saved {:process (. package.loaded :fen.util.process)
                    :runtime (. package.loaded :fen.runtime)
                    :discover (. package.loaded :fen.extensions.subagent.discover)
                    :subagent (. package.loaded :fen.extensions.subagent)})))
    (after_each
      (fn []
        (tset package.loaded :fen.util.process saved.process)
        (tset package.loaded :fen.runtime saved.runtime)
        (tset package.loaded :fen.extensions.subagent.discover saved.discover)
        (tset package.loaded :fen.extensions.subagent saved.subagent)))

    (it "registers the subagent tool"
      (fn []
        (fresh)
        (assert.is_true (tool-registered? :subagent))))

    (it "marks subagent parallel-safe with cap 4"
      (fn []
        (fresh)
        (let [tool (registered-tool :subagent)]
          (assert.is_truthy tool)
          (assert.is_true (. tool :parallel-safe?))
          (assert.are.equal 4 (. tool :parallel-cap)))))

    (it "returns the child's final text and usage on success"
      (fn []
        (var seen-argv nil)
        (install-mocks
          (fn [opts _yield]
            ;; Validate the spawn shape and write the result blob the tool
            ;; expects to decode back.
            (set seen-argv opts.argv)
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "found it"
                                     :usage {:input 10 :output 4 :total-tokens 14}
                                     :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 12 :output "ignored"})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "find the thing"})]
          (assert.is_false r.is-error?)
          (assert.are.equal "found it" (first-text r.content))
          (assert.are.equal 14 (. r.details :usage :total-tokens))
          (assert.are.equal "stop" (. r.details :stop-reason))
          (assert.are.equal 0 (. r.details :exit-code))
          ;; argv carries the json presenter, the task, a system file, and the
          ;; model override; never a shell string.
          (assert.is_truthy seen-argv)
          (let [joined (table.concat seen-argv " ")]
            (assert.is_truthy (string.find joined "--presenter json" 1 true))
            (assert.is_truthy (string.find joined "find the thing" 1 true))
            (assert.is_truthy (string.find joined "--system-file" 1 true))
            (assert.is_truthy (string.find joined "--model claude-haiku-4-5" 1 true))))))

    (it "passes requested cwd through spawn, PWD, task context, and details"
      (fn []
        (var seen-opts nil)
        (install-mocks
          (fn [opts _yield]
            (set seen-opts opts)
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:final-text "cwd ok" :stop-reason "stop"}))
              (f:close))
            {:exit-code 0 :timed-out? false :duration-ms 5 :output "ignored"})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "review the diff" :cwd "/tmp"})
              joined (table.concat seen-opts.argv " ")]
          (assert.is_false r.is-error?)
          (assert.are.equal "/tmp" seen-opts.cwd)
          (assert.are.equal "/tmp" (. seen-opts.env :PWD))
          (assert.is_truthy (string.find joined "Subagent launch context" 1 true))
          (assert.is_truthy (string.find joined "Requested cwd: /tmp" 1 true))
          (assert.is_truthy (string.find joined "Child PWD: /tmp" 1 true))
          (assert.is_truthy (string.find joined "review the diff" 1 true))
          (assert.are.equal "/tmp" (. r.details :requested-cwd))
          (assert.are.equal "/tmp" (. r.details :cwd))
          (assert.is_truthy (. r.details :physical-cwd)))))

    (it "flags an unknown agent as an error"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] nil))
        (fresh)
        (let [r (execute-tool {:agent :ghost :task "x"})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "unknown agent" 1 true)))))

    (it "flags a nonzero child exit as an error"
      (fn []
        (install-mocks
          (fn [opts _yield]
            (let [out-path (. opts.env :FEN_JSON_OUTPUT_PATH)
                  f (assert (io.open out-path :w))]
              (f:write (json.encode {:error "boom" :stop-reason "error"}))
              (f:close))
            {:exit-code 1 :timed-out? false :duration-ms 3 :output "boom"})
          (fn [name] (when (= name :scout) scout-cfg)))
        (fresh)
        (let [r (execute-tool {:agent :scout :task "do it"})]
          (assert.is_true r.is-error?)
          (assert.are.equal 1 (. r.details :exit-code)))))

    (it "errors when the task is missing"
      (fn []
        (install-mocks
          (fn [_opts _yield] (error "should not spawn"))
          (fn [_name] scout-cfg))
        (fresh)
        (let [r (execute-tool {:agent :scout})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "task" 1 true)))))))
