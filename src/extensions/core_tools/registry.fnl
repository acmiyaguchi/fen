;; Built-in core tool registry used by the core_tools extension and tests.

(local bash-tool (require :extensions.core_tools.bash))
(local read-tool (require :extensions.core_tools.read))
(local write-tool (require :extensions.core_tools.write))
(local ls-tool (require :extensions.core_tools.ls))
(local edit-tool (require :extensions.core_tools.edit))
(local grep-tool (require :extensions.core_tools.grep))
(local find-tool-mod (require :extensions.core_tools.find))

{:registry [bash-tool read-tool write-tool ls-tool edit-tool grep-tool find-tool-mod]}
