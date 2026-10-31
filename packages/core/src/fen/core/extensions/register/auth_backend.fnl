(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))
(local contrib (require :fen.core.extensions.contrib))

(local M {})

;; @doc fen.core.extensions.register.auth_backend.register
;; kind: function
;; signature: (register spec owner handle-result) -> register-result
;; summary: Validate and install a singleton auth-backend contribution keyed by :name for provider credential lookup.
;; tags: extensions register auth
(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :auth-backend requires {:name ...}"))
  (let [(_record unregister) (contrib.add! owner :auth-backends spec.name
                                          (util.deep-copy spec))]
    (handle-result :auth-backend spec.name owner unregister)))

;; @doc fen.core.extensions.register.auth_backend.find
;; kind: function
;; signature: (find name) -> AuthBackend|nil
;; summary: Return the registered auth backend for name, or nil when no matching backend is installed.
;; tags: extensions register auth
(fn M.find [name]
  (. state.auth-backends name))

;; @doc fen.core.extensions.register.auth_backend.list
;; kind: function
;; signature: (list) -> [AuthBackendInfo]
;; summary: Return auth backend metadata for introspection, including owner and optional credential capability flags.
;; tags: extensions register auth introspection
(fn M.list []
  (let [out []]
    (each [name b (pairs state.auth-backends)]
      (table.insert out
                    {:name name
                     :owner b.__owner
                     :has-configured? (= (type b.configured?) :function)
                     :has-get-fresh-creds? (= (type b.get-fresh-creds!)
                                              :function)}))
    out))

M
