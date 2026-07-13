;; Built-in tool registry used by the builtin_tools extension and tests.

;; @doc fen.extensions.builtin_tools.registry.registry
;; kind: data
;; signature: [AgentToolSpec]
;; summary: Ordered list of built-in tool specifications registered by the builtin-tools extension and reused by tests.
;; tags: builtin tools registry

(local bash-tool (require :fen.extensions.builtin_tools.bash))
(local read-tool (require :fen.extensions.builtin_tools.read))
(local write-tool (require :fen.extensions.builtin_tools.write))
(local ls-tool (require :fen.extensions.builtin_tools.ls))
(local edit-tool (require :fen.extensions.builtin_tools.edit))
(local grep-tool (require :fen.extensions.builtin_tools.grep))
(local find-tool-mod (require :fen.extensions.builtin_tools.find))
(local tool-search (require :fen.extensions.builtin_tools.tool_search))

{:registry [bash-tool read-tool write-tool ls-tool edit-tool grep-tool find-tool-mod
            tool-search]}
