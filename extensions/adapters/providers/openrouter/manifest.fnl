{:name :provider_openrouter
 :description "First-party OpenRouter provider (curated OpenAI-Chat-Completions-compatible gateway models)."
 :entry-module :fen.extensions.provider_openrouter
 :reload-modules [:fen.extensions.provider_openrouter.openrouter_completions
                  :fen.extensions.provider_openrouter]}
