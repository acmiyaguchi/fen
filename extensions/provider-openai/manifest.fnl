{:name :provider_openai
 :description "First-party OpenAI providers (Chat Completions and Responses)."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.provider_openai
 :reload-modules [:fen.extensions.provider_openai.openai_completions
                  :fen.extensions.provider_openai.openai_responses_shared
                  :fen.extensions.provider_openai.openai_responses
                  :fen.extensions.provider_openai]}
