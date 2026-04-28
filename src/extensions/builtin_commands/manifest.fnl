{:name :builtin_commands
 :description "Built-in agent-fennel slash commands: status, new, reload, queue, help."
 :reload-modules [:extensions.builtin_commands.util
                  :extensions.builtin_commands.commands.status
                  :extensions.builtin_commands.commands.session
                  :extensions.builtin_commands.commands.extension
                  :extensions.builtin_commands.commands.queue
                  :extensions.builtin_commands.commands.help
                  :extensions.builtin_commands]
 :enabled-by-default true}
