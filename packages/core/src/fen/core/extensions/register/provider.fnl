(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

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
    (let [(tagged unregister) (util.set-tagged! state.providers name spec* owner)]
      (handle-result :provider name owner unregister))))

;; @doc fen.core.extensions.register.provider.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Remove every provider installed by owner without clobbering same-name providers registered later by other owners.
;; tags: extensions providers reload
(fn M.unregister-by-owner [owner]
  (each [name p (pairs state.providers)]
    (when (= p.__owner owner)
      (tset state.providers name nil))))

;; @doc fen.core.extensions.register.provider.find
;; kind: function
;; signature: (find name) -> Provider|nil
;; summary: Find a provider by its unique registry name; provider :api is protocol metadata, not the deterministic dispatch key.
;; tags: extensions providers lookup
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
