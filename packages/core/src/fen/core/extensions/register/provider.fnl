(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

(fn M.register [spec owner handle-result]
  (when (or (not spec) (and (not spec.name) (not spec.api)))
    (error "register :provider requires {:name ...}"))
  (when (not spec.complete)
    (error "register :provider requires {:complete ...}"))
  (let [name (or spec.name spec.api)
        tagged (util.deep-copy spec)]
    (when (not tagged.name) (set tagged.name name))
    (tset tagged :__owner owner)
    (tset state.providers name tagged)
    (handle-result :provider name owner
      (fn []
        (when (= (. state.providers name) tagged)
          (tset state.providers name nil))))))

(fn M.unregister-by-owner [owner]
  (each [name p (pairs state.providers)]
    (when (= p.__owner owner)
      (tset state.providers name nil))))

(fn M.find [name]
  "Find a provider by its unique registry name. Provider :api is protocol
   metadata and is intentionally not part of deterministic dispatch."
  (. state.providers name))

(fn M.list-by-api [api]
  "Return all providers whose protocol/family metadata matches api. This is
   for introspection/delegation, not completion dispatch."
  (let [out []
        needle (tostring api)]
    (each [_ p (pairs state.providers)]
      (when (= (tostring p.api) needle)
        (table.insert out p)))
    out))

(fn M.find-by-api [api]
  "Return one provider matching api, for legacy/introspection callers. Do not
   use this as a completion dispatch key when more than one provider may share
   an api."
  (. (M.list-by-api api) 1))

(fn M.list []
  (let [out []]
    (each [name p (pairs state.providers)]
      (table.insert out {:name name
                         :api p.api
                         :owner p.__owner
                         :provider p.provider
                         :default-model p.default-model
                         :models p.models
                         :api-key p.api-key
                         :base-url p.base-url
                         :compat p.compat
                         :api-key-var p.api-key-var
                         :auth-backend p.auth-backend}))
    out))

M
