;; Tool registry and executor.
;;
;; Each built-in tool lives in its own module under core.tools.*. This module is
;; the public entrypoint: it assembles the default registry and exposes helpers
;; for provider descriptors and execution.

(local util (require :core.tools.util))
(local bash-tool (require :core.tools.bash))
(local read-tool (require :core.tools.read))
(local write-tool (require :core.tools.write))
(local ls-tool (require :core.tools.ls))
(local edit-tool (require :core.tools.edit))
(local grep-tool (require :core.tools.grep))
(local find-tool-mod (require :core.tools.find))

(local registry
  [bash-tool read-tool write-tool ls-tool edit-tool grep-tool find-tool-mod])

(fn find-tool [reg name]
  (var found nil)
  (each [_ t (ipairs reg)]
    (when (and (= found nil) (= (tostring t.name) (tostring name)))
      (set found t)))
  found)

(fn descriptors [reg]
  "Strip execute/label → canonical Tool[] (the shape providers wrap)."
  (let [out []]
    (each [_ t (ipairs reg)]
      (table.insert out
                    {:name t.name
                     :description t.description
                     :parameters t.parameters}))
    out))

(fn execute [reg name args ctx]
  "Look up a tool by name and run it."
  (let [t (find-tool reg name)]
    (if (not t)
        (util.err (.. "unknown tool: " (tostring name)))
        t.execute-with-context
        (t.execute-with-context (or args {}) ctx)
        (t.execute (or args {})))))

(fn execute-coop [reg name args yield-fn ctx]
  "Like execute but routes to :execute-coop when present."
  (let [t (find-tool reg name)]
    (if (not t)
        (util.err (.. "unknown tool: " (tostring name)))
        t.execute-coop
        (t.execute-coop (or args {}) yield-fn)
        t.execute-with-context
        (t.execute-with-context (or args {}) ctx)
        (t.execute (or args {})))))

{: registry : descriptors : execute : execute-coop : find-tool}
