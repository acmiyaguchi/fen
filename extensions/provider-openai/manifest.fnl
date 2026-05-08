{:name :provider_openai
 :description "First-party OpenAI provider family (Chat Completions, Responses, Codex subscription, and Codex OAuth auth)."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.provider_openai
 :reload-modules [:fen.extensions.provider_openai.openai_completions
                  :fen.extensions.provider_openai.openai_responses_shared
                  :fen.extensions.provider_openai.openai_responses
                  :fen.extensions.provider_openai.openai_codex_keychain
                  :fen.extensions.provider_openai.openai_codex_oauth
                  :fen.extensions.provider_openai.openai_codex_login
                  :fen.extensions.provider_openai.openai_codex_responses
                  :fen.extensions.provider_openai]}
