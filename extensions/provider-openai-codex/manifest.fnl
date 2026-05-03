{:name :provider_openai_codex
 :description "First-party ChatGPT Codex subscription provider and OAuth auth backend."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.provider_openai_codex
 :reload-modules [:fen.providers.openai_codex_keychain
                  :fen.providers.openai_codex_oauth
                  :fen.providers.openai_responses_shared
                  :fen.providers.openai_responses
                  :fen.providers.openai_codex_responses
                  :fen.extensions.provider_openai_codex]}
