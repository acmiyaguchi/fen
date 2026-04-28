;; Tool executor/helpers.
;;
;; core.tools is the shared runtime for provider descriptors and tool
;; execution. Built-in tool implementations live in extensions.core_tools and
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
        (t.execute-coop (or args {}) yield-fn)
        t.execute-with-context
        (t.execute-with-context (or args {}) ctx)
        (t.execute (or args {})))))

{: descriptors : execute : execute-coop : find-tool}
