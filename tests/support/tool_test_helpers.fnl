;; Shared helpers for core.tools and first-party tool extension tests.

(local tools (require :core.tools))
(local builtin-tools (require :extensions.builtin_tools.registry))
(local extensions (require :core.extensions))
(local registry builtin-tools.registry)
(local types (require :core.types))
(local json (require :util.json))
(local h (require :test_helpers))

(local read-file h.read-file!)

(fn first-text [content]
  "Extract the text from the first TextContent block of an AgentToolResult."
  (let [b (. content 1)]
    (if (and b (= b.type :text)) b.text "")))

(fn execute [reg name args ?ctx]
  "Test helper over the compact core.tools API; returns AgentToolResult."
  (let [out (tools.execute-call reg
                                {:type :tool-call
                                 :id "test-call"
                                 :name name
                                 :arguments args}
                                ?ctx)]
    out.result))

(fn execute-coop [reg name args yield-fn ?ctx]
  "Test helper over execute-call with a yield-fn; returns AgentToolResult."
  (let [out (tools.execute-call reg
                                {:type :tool-call
                                 :id "test-call"
                                 :name name
                                 :arguments args}
                                ?ctx
                                yield-fn)]
    out.result))

{: tools
 : builtin-tools
 : extensions
 : registry
 : types
 : json
 : h
 : read-file
 : first-text
 : execute
 : execute-coop}
