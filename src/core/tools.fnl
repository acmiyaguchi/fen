;; Tool executor/helpers.
;;
;; core.tools is the shared runtime for provider descriptors and tool
;; execution. Built-in tool implementations live in extensions.builtin_tools and
;; are registered through that first-party extension like any other tools.

(local types (require :core.types))
(local extensions (require :core.extensions))

(fn err [message]
  {:content [(types.text-block (.. "error: " message))]
   :is-error? true})

(fn find-tool [reg name]
  (var found nil)
  (each [_ t (ipairs (or reg []))]
    (when (and (= found nil) (= (tostring t.name) (tostring name)))
      (set found t)))
  found)

(fn descriptors [reg]
  "Strip execute/label → canonical Tool[] (the shape providers wrap)."
  (let [out []]
    (each [_ t (ipairs (or reg []))]
      (table.insert out
                    {:name t.name
                     :description t.description
                     :parameters t.parameters}))
    out))

(fn tool-error [tool-name thrown]
  (err (.. "tool " (tostring tool-name) " failed: " (tostring thrown))))

(fn blocked-error [tool-name reason]
  (err (.. "tool " (tostring tool-name) " blocked"
           (if reason (.. ": " (tostring reason)) ""))))

(fn call-tool [tool-name f ...]
  (let [(ok? result) (pcall f ...)]
    (if ok? result (tool-error tool-name result))))

(fn check-before-tool [name args ctx]
  (let [decision (extensions.run-before-tool name (or args {}) ctx)]
    (when (and decision decision.block?)
      (blocked-error name decision.reason))))

(fn execute [reg name args ctx]
  "Look up a tool by name and run it."
  (let [t (find-tool reg name)
        safe-args (or args {})]
    (if (not t)
        (err (.. "unknown tool: " (tostring name)))
        (let [blocked (check-before-tool name safe-args ctx)]
          (if blocked
              blocked
              t.execute-with-context
              (call-tool name t.execute-with-context safe-args ctx)
              (call-tool name t.execute safe-args))))))

(fn execute-coop [reg name args yield-fn ctx]
  "Like execute but routes to :execute-coop when present."
  (let [t (find-tool reg name)
        safe-args (or args {})]
    (if (not t)
        (err (.. "unknown tool: " (tostring name)))
        (let [blocked (check-before-tool name safe-args ctx)]
          (if blocked
              blocked
              t.execute-coop
              ;; Do not pcall :execute-coop: cancellation propagates through the
              ;; same error channel from yield-fn and must unwind the agent turn.
              (t.execute-coop safe-args yield-fn ctx)
              t.execute-with-context
              (call-tool name t.execute-with-context safe-args ctx)
              (call-tool name t.execute safe-args))))))

(fn execute-call [reg tool-call ctx]
  "Execute one canonical ToolCall block and wrap the result as a ToolResultMessage."
  (let [started-at (os.time)
        result (execute reg tool-call.name tool-call.arguments ctx)
        duration-seconds (- (os.time) started-at)
        msg (types.tool-result-message
              {:tool-call-id tool-call.id
               :tool-name tool-call.name
               :content result.content
               :is-error? result.is-error?
               :details result.details})]
    {:message msg
     :result result
     :duration-seconds duration-seconds
     :tool-call tool-call}))

(fn execute-call-coop [reg tool-call yield-fn ctx]
  "Cooperative variant of execute-call; prefers tool :execute-coop when present."
  (let [started-at (os.time)
        result (execute-coop reg tool-call.name tool-call.arguments yield-fn ctx)
        duration-seconds (- (os.time) started-at)
        msg (types.tool-result-message
              {:tool-call-id tool-call.id
               :tool-name tool-call.name
               :content result.content
               :is-error? result.is-error?
               :details result.details})]
    {:message msg
     :result result
     :duration-seconds duration-seconds
     :tool-call tool-call}))

{: descriptors : execute-call : execute-call-coop}
