(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

(local REQUIRED [:open :open-existing :append :close :load :find :list :latest])

(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :session-backend requires {:name ...}"))
  (each [_ k (ipairs REQUIRED)]
    (when (not= (type (. spec k)) :function)
      (error (.. "register :session-backend requires {:" (tostring k) " ...}"))))
  (let [name spec.name
        (tagged unregister) (util.set-tagged! state.session-backends name spec owner)]
    (handle-result :session-backend name owner unregister)))

(fn M.unregister-by-owner [owner]
  (each [name backend (pairs state.session-backends)]
    (when (= backend.__owner owner)
      (when (= state.session.backend backend)
        (set state.session.backend nil)
        (set state.session.info nil))
      (tset state.session-backends name nil))))

(fn M.find [name]
  (. state.session-backends name))

(fn M.set-active! [name]
  (set state.session.active-name name)
  (set state.session.backend (and name (M.find name)))
  state.session.backend)

(fn M.active []
  (or state.session.backend
      (and state.session.active-name (M.find state.session.active-name))))

(fn M.set-info! [info]
  (set state.session.info info)
  info)

(fn M.info [] state.session.info)

(fn M.list []
  (let [out []]
    (each [name backend (pairs state.session-backends)]
      (table.insert out {:name name :owner backend.__owner}))
    out))

M
