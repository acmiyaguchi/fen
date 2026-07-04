{:name :provider_shared
 :description "Shared transport helpers for first-party provider adapters (retry/backoff). Registers no user-facing surface."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.provider_shared
 :reload-modules [:fen.extensions.provider_shared.retry
                  :fen.extensions.provider_shared.streaming
                  :fen.extensions.provider_shared]}
