{:name :prompt
 :description "Prompt inspector: /prompt command and prompt-fragment panel."
 :entry-module :fen.extensions.prompt
 :reload-modules [:fen.extensions.prompt.commands.prompt
                  :fen.extensions.prompt]
 :reload-exclude [:fen.extensions.prompt.state.prompt]}
