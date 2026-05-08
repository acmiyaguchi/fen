;; Tool executor/helpers.
;;
;; core.tools is the shared runtime for provider descriptors and tool
;; execution. Built-in tool implementations live in extensions.builtin_tools and
;; are registered through that first-party extension like any other tools.

(local types (require :fen.core.types))
(local hook-registry (require :fen.core.extensions.register.hook))

(fn err [message]
  {:content [(types.text-block (.. "error: " message))]
   :is-error? true})

(fn find-tool [reg name]
  (var found nil)
  (each [_ t (ipairs (or reg []))]
    (when (and (= found nil) (= (tostring t.name) (tostring name)))
      (set found t)))
  found)

;; @doc fen.core.tools.descriptors
;; kind: function
;; signature: (descriptors reg) -> [Tool]
;; summary: Strip executable AgentTool records down to canonical Tool descriptors passed to providers.
;; tags: tools providers
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
  (let [decision (hook-registry.run-before-tool name (or args {}) ctx)]
    (when (and decision decision.block?)
      (blocked-error name decision.reason))))

(fn execute [reg name args ctx ?yield-fn]
  "Look up a tool by name and run it. Every tool exports a single
   `:execute(args, ctx, ?yield-fn)` method; the tool decides what to do
   with the optional positional args (most ignore both, bash uses
   ?yield-fn, agent_state uses ctx).

   Pcall policy: when `?yield-fn` is nil (blocking caller) the tool body
   runs inside `call-tool`'s pcall and any error becomes an AgentToolResult
   with is-error?. When `?yield-fn` is given (cooperative caller) the body
   runs uncaught so cancellation raised through yield-fn unwinds cleanly to
   the agent's outer pcall; coop tools that pcall internal I/O must
   re-raise yield-side errors themselves (see bash's run-bash-impl)."
  (let [t (find-tool reg name)
        safe-args (or args {})]
    (if (not t)
        (err (.. "unknown tool: " (tostring name)))
        (let [blocked (check-before-tool name safe-args ctx)]
          (if blocked
              blocked
              ?yield-fn
              (t.execute safe-args ctx ?yield-fn)
              (call-tool name t.execute safe-args ctx))))))

;; @doc fen.core.tools.execute-call
;; kind: function
;; signature: (execute-call reg tool-call ctx ?yield-fn) -> {:message :result :duration-seconds :tool-call}
;; summary: Execute one canonical ToolCall against the registered tools and wrap the result as a ToolResultMessage plus diagnostics.
;; tags: tools agent
(fn execute-call [reg tool-call ctx ?yield-fn]
  "Execute one canonical ToolCall block and wrap the result as a
   ToolResultMessage. Cooperative when `?yield-fn` is passed."
  (let [started-at (os.time)
        result (execute reg tool-call.name tool-call.arguments ctx ?yield-fn)
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

{: descriptors : execute-call}
