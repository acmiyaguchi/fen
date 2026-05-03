{:name :provider_openai
 :description "First-party OpenAI providers (Chat Completions and Responses)."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.provider_openai
 :reload-modules [:fen.providers.openai_completions
                  :fen.providers.openai_responses_shared
                  :fen.providers.openai_responses
                  :fen.extensions.provider_openai]}
