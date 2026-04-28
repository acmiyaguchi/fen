;; Tool executor/helpers.
;;
;; core.tools is the shared runtime for provider descriptors and tool
;; execution. Built-in tool implementations live in extensions.builtin_tools and
;; are registered through that first-party extension like any other tools.

(local types (require :core.types))

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

(fn execute [reg name args ctx]
  "Look up a tool by name and run it."
  (let [t (find-tool reg name)]
    (if (not t)
        (err (.. "unknown tool: " (tostring name)))
        t.execute-with-context
        (t.execute-with-context (or args {}) ctx)
        (t.execute (or args {})))))

(fn execute-coop [reg name args yield-fn ctx]
  "Like execute but routes to :execute-coop when present."
  (let [t (find-tool reg name)]
    (if (not t)
        (err (.. "unknown tool: " (tostring name)))
        t.execute-coop
        (t.execute-coop (or args {}) yield-fn ctx)
        t.execute-with-context
        (t.execute-with-context (or args {}) ctx)
        (t.execute (or args {})))))

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
