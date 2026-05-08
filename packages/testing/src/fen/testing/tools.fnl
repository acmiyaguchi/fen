;; Shared helpers for core.tools and first-party tool extension tests.

(local h (require :fen.testing))
(local read-file h.read-file!)

(fn require-core-tools [] (require :fen.core.tools))
(fn require-builtin-tools [] (require :fen.extensions.builtin_tools.registry))
(fn require-extensions []
  {:reset! (. (require :fen.core.extensions.test_api) :reset!)
   :register (. (require :fen.core.extensions.register) :register)
   :list (. (require :fen.core.extensions.register) :list)
   :merged-tools (. (require :fen.core.extensions.register.tool) :merged)
   :run-before-tool (. (require :fen.core.extensions.register.hook) :run-before-tool)
   :emit (. (require :fen.core.extensions.events) :emit)
   :on (. (require :fen.core.extensions.events) :on)})
(fn require-types [] (require :fen.core.types))
(fn require-json [] (require :fen.util.json))

(fn first-text [content]
  "Extract the text from the first TextContent block of an AgentToolResult."
  (let [b (. content 1)]
    (if (and b (= b.type :text)) b.text "")))

(fn execute [reg name args ?ctx]
  "Test helper over the compact core.tools API; returns AgentToolResult."
  (let [tools (require-core-tools)
        out (tools.execute-call reg
                                {:type :tool-call
                                 :id "test-call"
                                 :name name
                                 :arguments args}
                                ?ctx)]
    out.result))

(fn execute-coop [reg name args yield-fn ?ctx]
  "Test helper over execute-call with a yield-fn; returns AgentToolResult."
  (let [tools (require-core-tools)
        out (tools.execute-call reg
                                {:type :tool-call
                                 :id "test-call"
                                 :name name
                                 :arguments args}
                                ?ctx
                                yield-fn)]
    out.result))

(local M
  {: h
   : read-file
   : first-text
   : execute
   : execute-coop})

(setmetatable M
  {:__index
   (fn [_ k]
     (case k
       :tools (require-core-tools)
       :builtin-tools (require-builtin-tools)
       :extensions (require-extensions)
       :registry (. (require-builtin-tools) :registry)
       :types (require-types)
       :json (require-json)
       _ nil))})

M
