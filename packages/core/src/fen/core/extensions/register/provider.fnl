(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))
(local contrib (require :fen.core.extensions.contrib))

(local M {})

;; @doc fen.core.extensions.register.provider.register
;; kind: function
;; signature: (register spec owner handle-result) -> register-result
;; summary: Validate and install a singleton provider contribution keyed by name, defaulting name from api when omitted.
;; tags: extensions register providers
(fn M.register [spec owner handle-result]
  (when (or (not spec) (and (not spec.name) (not spec.api)))
    (error "register :provider requires {:name ...}"))
  (when (not spec.complete)
    (error "register :provider requires {:complete ...}"))
  (let [name (or spec.name spec.api)
        spec* (util.deep-copy spec)]
    (when (not spec*.name) (set spec*.name name))
    (let [(_record unregister) (contrib.add! owner :providers name spec*)]
      (handle-result :provider name owner unregister))))

(fn M.find [name]
  "Find a provider by its unique registry name. Provider :api is protocol
   metadata and is intentionally not part of deterministic dispatch."
  (. state.providers name))

;; @doc fen.core.extensions.register.provider.list
;; kind: function
;; signature: (list) -> [ProviderInfo]
;; summary: Return provider metadata for model selection, docs, and diagnostics while preserving provider implementation records internally.
;; tags: extensions providers introspection
(fn M.list []
  (let [out []]
    (each [name p (pairs state.providers)]
      (table.insert out {:name name
                         :api p.api
                         :owner p.__owner
                         :provider p.provider
                         :default-model p.default-model
                         :models p.models
                         :list-models p.list-models
                         :api-key p.api-key
                         :base-url p.base-url
                         :compat p.compat
                         :api-key-var p.api-key-var
                         :auth-backend p.auth-backend}))
    out))

M
