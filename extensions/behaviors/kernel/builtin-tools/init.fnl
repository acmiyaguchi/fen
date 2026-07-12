;; First-party built-in tool extension.
;;
;; Registers the built-in fen tool surface through the same extension
;; API used by external tools. The implementations live beside this file;
;; core.tools itself is the shared executor/helper module.

(local builtin-tools (require :fen.extensions.builtin_tools.registry))

(local M {})

(fn M.register [api]

(each [_ tool (ipairs builtin-tools.registry)]
  ;; The kernel workspace surface is always provider-visible. Other extension
  ;; tools remain executable but are advertised only after tool_search activates
  ;; them for this agent.
  (set tool.exposure :always)
  ;; @doc register-site:tool:builtin-tool-registry
  ;; summary: Dynamic loop registering every built-in tool spec from the builtin tools registry.
  ;; tags: tool builtin registry
  (api.register :tool tool))

  true)

M
