{:name :provider_mock
 :description "Deterministic, scriptable mock provider for tests, smoke runs, and offline dev."
 :enabled-by-default false
 :first-party? true
 :entry-module :fen.extensions.provider_mock
 :reload-modules [:fen.extensions.provider_mock.mock_provider
                  :fen.extensions.provider_mock]}
