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

(fn M.find [name-or-api]
  (or (. state.providers name-or-api)
      (let [needle (tostring name-or-api)]
        (var found nil)
        (each [_ p (pairs state.providers) &until found]
          (when (= (tostring p.api) needle)
            (set found p)))
        found)))

(fn M.list []
  (let [out []]
    (each [name p (pairs state.providers)]
      (table.insert out {:name name
                         :api p.api
                         :owner p.__owner
                         :provider p.provider
                         :default-model p.default-model
                         :api-key-var p.api-key-var
                         :auth-backend p.auth-backend}))
    out))

M
