{:name :core_tools
 :description "Built-in agent-fennel tools: bash, read, write, ls, edit, grep, find."
 :reload-modules [:extensions.core_tools.util
                  :extensions.core_tools.truncate
                  :extensions.core_tools.bash
                  :extensions.core_tools.read
                  :extensions.core_tools.write
                  :extensions.core_tools.ls
                  :extensions.core_tools.edit
                  :extensions.core_tools.grep
                  :extensions.core_tools.find
                  :extensions.core_tools.registry
                  :extensions.core_tools]
 :enabled-by-default true}
