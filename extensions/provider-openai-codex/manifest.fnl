{:name :provider_openai_codex
 :description "First-party ChatGPT Codex subscription provider and OAuth auth backend."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.provider_openai_codex
 :reload-modules [:fen.extensions.provider_openai_codex.openai_codex_keychain
                  :fen.extensions.provider_openai_codex.openai_codex_oauth
                  :fen.extensions.provider_openai.openai_responses_shared
                  :fen.extensions.provider_openai.openai_responses
                  :fen.extensions.provider_openai_codex.openai_codex_responses
                  :fen.extensions.provider_openai_codex]}
