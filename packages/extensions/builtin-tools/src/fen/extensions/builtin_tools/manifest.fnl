{:name :builtin_tools
 :description "Built-in fen tools: bash, read, write, ls, edit, grep, find."
 :reload-modules [:fen.extensions.builtin_tools.util
                  :fen.extensions.builtin_tools.truncate
                  :fen.extensions.builtin_tools.bash
                  :fen.extensions.builtin_tools.read
                  :fen.extensions.builtin_tools.write
                  :fen.extensions.builtin_tools.ls
                  :fen.extensions.builtin_tools.edit
                  :fen.extensions.builtin_tools.grep
                  :fen.extensions.builtin_tools.find
                  :fen.extensions.builtin_tools.registry
                  :fen.extensions.builtin_tools]
 :enabled-by-default true}
