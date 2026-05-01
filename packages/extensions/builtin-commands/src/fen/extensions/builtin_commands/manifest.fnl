{:name :builtin_commands
 :description "Built-in fen slash commands: status, new, reload, prompt, queue, help."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.builtin_commands
 :reload-modules [:fen.extensions.builtin_commands.util
                  :fen.extensions.builtin_commands.commands.status
                  :fen.extensions.builtin_commands.commands.session
                  :fen.extensions.builtin_commands.commands.extension
                  :fen.extensions.builtin_commands.commands.prompt
                  :fen.extensions.builtin_commands.commands.queue
                  :fen.extensions.builtin_commands.commands.help
                  :fen.extensions.builtin_commands]}
