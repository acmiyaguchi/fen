(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

(local REQUIRED [:open :open-existing :append :close :load :find :list :latest])
;; Optional methods:
;;   :append-entry (fn [session entry] -> entry|nil)
;;     Append a non-message JSONL/session entry such as :compaction or
;;     :extension-state. Backends that support it should fill stable :id,
;;     :parent-id, and :timestamp when absent.
;;   :latest-extension-state (fn [session extension] -> entry|nil)
;;     Return the latest valid :extension-state entry owned by extension.
;; Optional methods keep simple or third-party backends valid.

;; @doc fen.core.extensions.register.session_backend.register
;; kind: function
;; signature: (register spec owner handle-result) -> register-result
;; summary: Validate required session backend methods and install the backend by name for session persistence selection.
;; tags: extensions register session
(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :session-backend requires {:name ...}"))
  (each [_ k (ipairs REQUIRED)]
    (when (not= (type (. spec k)) :function)
      (error (.. "register :session-backend requires {:" (tostring k) " ...}"))))
  (let [name spec.name
        (tagged unregister) (util.set-tagged! state.session-backends name spec owner)]
    (handle-result :session-backend name owner unregister)))

;; @doc fen.core.extensions.register.session_backend.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Remove session backends installed by owner and clear active session state if the active backend is removed.
;; tags: extensions session reload
(fn M.unregister-by-owner [owner]
  (each [name backend (pairs state.session-backends)]
    (when (= backend.__owner owner)
      (when (= state.session.backend backend)
        (set state.session.backend nil)
        (set state.session.info nil))
      (tset state.session-backends name nil))))

;; @doc fen.core.extensions.register.session_backend.find
;; kind: function
;; signature: (find name) -> SessionBackend|nil
;; summary: Return the registered session backend for name, or nil when no backend is installed under that name.
;; tags: extensions session lookup
(fn M.find [name]
  (. state.session-backends name))

;; @doc fen.core.extensions.register.session_backend.set-active!
;; kind: function
;; signature: (set-active! name) -> SessionBackend|nil
;; summary: Record the active session backend name, resolve it immediately, and return the selected backend if present.
;; tags: extensions session state
(fn M.set-active! [name]
  (set state.session.active-name name)
  (set state.session.backend (and name (M.find name)))
  state.session.backend)

;; @doc fen.core.extensions.register.session_backend.active
;; kind: function
;; signature: (active) -> SessionBackend|nil
;; summary: Return the cached active backend or resolve the active backend name after reload restored the registry.
;; tags: extensions session state
(fn M.active []
  (or state.session.backend
      (and state.session.active-name (M.find state.session.active-name))))

;; @doc fen.core.extensions.register.session_backend.set-info!
;; kind: function
;; signature: (set-info! info ?handle) -> info
;; summary: Store active session metadata and, when supplied, its backend handle for extension-owned state entries.
;; tags: extensions session introspection state
(fn M.set-info! [info ?handle]
  (set state.session.info info)
  (set state.session.handle ?handle)
  info)

(fn json-friendly? [value seen]
  (let [kind (type value)]
    (if (or (= kind :nil) (= kind :string) (= kind :boolean))
        true
        (= kind :number)
        (and (= value value) (> value (- math.huge)) (< value math.huge))
        (= kind :table)
        (if (. seen value)
            false
            (do
              (tset seen value true)
              (var valid? true)
              (each [k v (pairs value) &until (not valid?)]
                (when (or (not (or (= (type k) :string) (= (type k) :number)))
                          (not (json-friendly? v seen)))
                  (set valid? false)))
              (tset seen value nil)
              valid?))
        false)))

;; @doc fen.core.extensions.register.session_backend.append-extension-state!
;; kind: function
;; signature: (append-extension-state! extension state ?version) -> entry|nil
;; summary: Append JSON-friendly state owned by one extension to the active session when the backend supports generic entries.
;; tags: extensions session state persistence
(fn M.append-extension-state! [extension value ?version]
  (let [version (or ?version 1)]
    (when (or (not extension)
              (not= (type version) :number)
              (not= version (math.floor version))
              (< version 1))
      (error "extension session state requires an owner and positive integer version"))
    (when (or (not= (type value) :table)
              (not (json-friendly? value {})))
      (error "extension session state must be a JSON-friendly table"))
    (let [backend (M.active)
          handle state.session.handle
          append-entry (and backend backend.append-entry)]
      (when (and handle append-entry)
        (append-entry handle {:type :extension-state
                              :extension extension
                              :version version
                              :state value})))))

;; @doc fen.core.extensions.register.session_backend.latest-extension-state
;; kind: function
;; signature: (latest-extension-state extension ?yield-fn) -> state,entry|nil
;; summary: Return the latest valid state and entry owned by one extension in the active session.
;; tags: extensions session state replay
(fn M.latest-extension-state [extension ?yield-fn]
  (let [backend (M.active)
        handle state.session.handle
        latest (and backend backend.latest-extension-state)
        entry (and handle latest (latest handle extension ?yield-fn))]
    (when entry
      (values entry.state entry))))

;; @doc fen.core.extensions.register.session_backend.info
;; kind: function
;; signature: (info) -> SessionInfo|nil
;; summary: Return the cached active session info record without touching backend storage.
;; tags: extensions session introspection
(fn M.info [] state.session.info)

;; @doc fen.core.extensions.register.session_backend.list
;; kind: function
;; signature: (list) -> [SessionBackendInfo]
;; summary: Return session backend names and owners for diagnostics and generated runtime documentation.
;; tags: extensions session introspection
(fn M.list []
  (let [out []]
    (each [name backend (pairs state.session-backends)]
      (table.insert out {:name name :owner backend.__owner}))
    out))

M
