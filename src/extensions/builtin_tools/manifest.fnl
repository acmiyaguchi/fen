{:name :builtin_tools
 :description "Built-in fen tools: bash, read, write, ls, edit, grep, find."
 :reload-modules [:extensions.builtin_tools.util
                  :extensions.builtin_tools.truncate
                  :extensions.builtin_tools.bash
                  :extensions.builtin_tools.read
                  :extensions.builtin_tools.write
                  :extensions.builtin_tools.ls
                  :extensions.builtin_tools.edit
                  :extensions.builtin_tools.grep
                  :extensions.builtin_tools.find
                  :extensions.builtin_tools.registry
                  :extensions.builtin_tools]
 :enabled-by-default true}
