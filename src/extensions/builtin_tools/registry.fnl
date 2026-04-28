;; Built-in tool registry used by the builtin_tools extension and tests.

(local bash-tool (require :extensions.builtin_tools.bash))
(local read-tool (require :extensions.builtin_tools.read))
(local write-tool (require :extensions.builtin_tools.write))
(local ls-tool (require :extensions.builtin_tools.ls))
(local edit-tool (require :extensions.builtin_tools.edit))
(local grep-tool (require :extensions.builtin_tools.grep))
(local find-tool-mod (require :extensions.builtin_tools.find))

{:registry [bash-tool read-tool write-tool ls-tool edit-tool grep-tool find-tool-mod]}
