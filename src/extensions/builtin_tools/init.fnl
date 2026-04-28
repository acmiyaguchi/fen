;; First-party built-in tool extension.
;;
;; Registers the built-in agent-fennel tool surface through the same extension
;; API used by external tools. The implementations live beside this file;
;; core.tools itself is the shared executor/helper module.

(local builtin-tools (require :extensions.builtin_tools.registry))
(local extensions (require :core.extensions))

(extensions.unregister-by-owner :builtin_tools)
(local api (extensions.make-api :builtin_tools))

(each [_ tool (ipairs builtin-tools.registry)]
  (api.register :tool tool))

true
