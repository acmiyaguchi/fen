;; First-party core tool extension.
;;
;; Registers the built-in agent-fennel tool surface through the same extension
;; API used by external tools. The implementations live beside this file;
;; core.tools itself is the shared executor/helper module.

(local core-tools (require :extensions.core_tools.registry))
(local extensions (require :core.extensions))

(extensions.unregister-by-owner :core_tools)
(local api (extensions.make-api :core_tools))

(each [_ tool (ipairs core-tools.registry)]
  (api.register :tool tool))

true
