(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :auth-backend requires {:name ...}"))
  (let [tagged (util.deep-copy spec)]
    (tset tagged :__owner owner)
    (tset state.auth-backends spec.name tagged)
    (handle-result :auth-backend spec.name owner
      (fn []
        (when (= (. state.auth-backends spec.name) tagged)
          (tset state.auth-backends spec.name nil))))))

(fn M.unregister-by-owner [owner]
  (each [name b (pairs state.auth-backends)]
    (when (= b.__owner owner)
      (tset state.auth-backends name nil))))

(fn M.find [name]
  (. state.auth-backends name))

(fn M.list []
  (let [out []]
    (each [name b (pairs state.auth-backends)]
      (table.insert out {:name name
                         :owner b.__owner
                         :has-configured? (= (type b.configured?) :function)
                         :has-get-fresh-creds? (= (type b.get-fresh-creds!) :function)}))
    out))

M
