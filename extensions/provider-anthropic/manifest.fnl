{:name :provider_anthropic
 :description "First-party Anthropic Messages provider."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.provider_anthropic
 :reload-modules [:fen.providers.anthropic_messages
                  :fen.extensions.provider_anthropic]}
