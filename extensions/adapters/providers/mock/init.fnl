;; First-party deterministic mock provider extension.
;;
;; Off by default. Enable it for a dev/smoke run with `--extension` pointing at
;; this directory, then select it with `--provider mock`. The provider needs no
;; credentials. See docs/providers.md for the script format.

(local mock-provider (require :fen.extensions.provider_mock.mock_provider))

(fn provider-spec [provider name default-model]
  (let [spec {}]
    (each [k v (pairs provider)] (tset spec k v))
    (set spec.name name)
    (set spec.default-model default-model)
    spec))

(local M {})

(fn M.register [api]

;; @doc register-site:provider:mock
;; summary: Deterministic, scriptable mock provider; requires no credentials. Drive responses with FEN_MOCK_SCRIPT or the mock-script provider option.
;; tags: provider mock testing
(api.register :provider
              (provider-spec mock-provider :mock :mock))

  true)

M
