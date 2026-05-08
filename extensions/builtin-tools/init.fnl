;; First-party built-in tool extension.
;;
;; Registers the built-in fen tool surface through the same extension
;; API used by external tools. The implementations live beside this file;
;; core.tools itself is the shared executor/helper module.

(local builtin-tools (require :fen.extensions.builtin_tools.registry))
(local ext-api (require :fen.core.extensions.api))

(local api (ext-api.make-api :builtin_tools))

(each [_ tool (ipairs builtin-tools.registry)]
  ;; @doc register-site:tool:builtin-tool-registry
  ;; summary: Dynamic loop registering every built-in tool spec from the builtin tools registry.
  ;; tags: tool builtin registry
  (api.register :tool tool))

true
