;; Kind dispatcher for `api.register :foo ...` plus the cross-cutting
;; sweeps and lookups that touch every kind (unregister-by-owner, list).
;;
;; Each per-kind file owns: register, unregister-by-owner, list, and any
;; verbs unique to that kind (run/dispatch/render). This module only wires
;; generic kind dispatch, cross-kind owner cleanup, and cross-kind lists.
;;
;; Register storage follows two templates:
;; - contribution arrays for kinds where many entries coexist freely (tools,
;;   controls, status items, panels, hooks, presenters, prompt fragments);
;;   unregister closures remove by record identity.
;; - singleton dictionaries for kinds where names are unique (commands,
;;   providers, auth backends, session backends); unregister closures remove
;;   only the exact record they installed, so stale closures cannot clobber a
;;   newer registration.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))
(local events (require :fen.core.extensions.events))
(local tool (require :fen.core.extensions.register.tool))
(local command (require :fen.core.extensions.register.command))
(local control (require :fen.core.extensions.register.control))
(local status (require :fen.core.extensions.register.status))
(local panel (require :fen.core.extensions.register.panel))
(local hook (require :fen.core.extensions.register.hook))
(local input (require :fen.core.extensions.register.input))
(local prompt (require :fen.core.extensions.register.prompt))
(local presenter (require :fen.core.extensions.register.presenter))
(local introspect (require :fen.core.extensions.register.introspect))
(local provider (require :fen.core.extensions.register.provider))
(local auth-backend (require :fen.core.extensions.register.auth_backend))
(local session-backend (require :fen.core.extensions.register.session_backend))

(local M {})

(local REGISTER-KINDS
  [{:kind :tool :list-kind :tools :module tool :public? true}
   {:kind :command :list-kind :commands :module command :public? true}
   {:kind :control :list-kind :controls :module control :public? true}
   {:kind :status :list-kind :status :module status :public? true}
   {:kind :panel :list-kind :panels :module panel :public? true}
   {:kind :hook :list-kind :hooks :module hook :public? true}
   {:kind :input-handler :list-kind :input-handlers :module input :public? true}
   {:kind :presenter :list-kind :presenters :module presenter}
   {:kind :introspect :list-kind :introspectors :module introspect :public? true}
   {:kind :provider :list-kind :providers :module provider}
   {:kind :auth-backend :list-kind :auth-backends :module auth-backend}
   {:kind :session-backend :list-kind :session-backends :module session-backend}])

(local REGISTER-BY-KIND {})
(local LIST-BY-KIND {})
(each [_ entry (ipairs REGISTER-KINDS)]
  (tset REGISTER-BY-KIND entry.kind entry)
  (tset LIST-BY-KIND entry.list-kind entry))

(fn handle-result [kind name owner unregister]
  {: kind : name : owner : unregister})

(fn unknown-register-kind! [kind]
  (error (.. "unknown register kind: " (tostring kind))))

(fn unknown-list-kind! [kind]
  (error (.. "unknown list kind: " (tostring kind))))

;; @doc fen.core.extensions.register.public-register-kind?
;; kind: function
;; signature: (public-register-kind? kind) -> boolean
;; summary: Return true when kind may be registered by unprivileged extension APIs.
;; tags: extensions register dispatcher
(fn M.public-register-kind? [kind]
  (let [entry (. REGISTER-BY-KIND kind)]
    (= true (and entry entry.public?))))

;; @doc fen.core.extensions.register.register
;; kind: function
;; signature: (register kind spec owner) -> register-result
;; summary: Dispatch one extension contribution to the per-kind registry module and return its owner-tagged unregister handle.
;; tags: extensions register dispatcher
(fn M.register [kind spec owner]
  (let [entry (. REGISTER-BY-KIND kind)]
    (when (not entry)
      (unknown-register-kind! kind))
    ((. entry.module :register) spec owner handle-result)))

;; @doc fen.core.extensions.register.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Sweep every registry kind and event-handler bucket, removing contributions tagged with owner during reload or teardown.
;; tags: extensions register reload
(fn M.unregister-by-owner [owner]
  "Drop every registration tagged with owner."
  (each [_ entry (ipairs REGISTER-KINDS)]
    ((. entry.module :unregister-by-owner) owner))
  (prompt.unregister-by-owner owner)
  (events.unregister-by-owner owner)
  (tset state.extensions owner nil)
  nil)

(fn list-extensions []
  (let [out []]
    (each [name rec (pairs state.extensions)]
      (let [manifest (or rec.manifest {})]
        (table.insert out {:name name :status rec.status :path rec.path
                           :source rec.source
                           :version-count (or rec.version-count 1)
                           :versions (or rec.versions [])
                           :first-party? rec.first-party?
                           :description manifest.description
                           :entry-module (or manifest.entry-module
                                             manifest.entryModule)
                           :entry (or manifest.entry manifest.entryFile)
                           :interactive-only? (or manifest.interactive-only?
                                                  manifest.interactiveOnly
                                                  false)
                           :presenter manifest.presenter
                           :reload-modules (or manifest.reload-modules
                                               manifest.reloadModules
                                               [])
                           :reload-exclude (or manifest.reload-exclude
                                               manifest.reloadExclude
                                               [])
                           :error rec.error
                           :missing rec.missing})))
    out))

(local EXTRA-LISTERS
  {:extensions list-extensions
   :event-handlers events.list
   :prompt-fragments prompt.list})

;; @doc fen.core.extensions.register.list
;; kind: function
;; signature: (list kind) -> frozen-table
;; summary: Return a frozen introspection list for the requested registry kind, including extensions, hooks, event handlers, and prompt fragments.
;; tags: extensions register introspection
(fn M.list [kind]
  (let [entry (. LIST-BY-KIND kind)
        extra (. EXTRA-LISTERS kind)
        data (if entry
                 ((. entry.module :list))
                 extra
                 (extra)
                 (unknown-list-kind! kind))]
    (util.freeze data)))

;; @doc fen.core.extensions.register.handle-input
;; kind: function
;; signature: (handle-input input ctx) -> action
;; summary: Dispatch non-slash user input through the ordered input-handler pipeline and return the resolving action.
;; tags: extensions input dispatch
(fn M.handle-input [in ctx]
  (input.handle in ctx))

;; @doc fen.core.extensions.register.collect-introspection
;; kind: function
;; signature: (collect-introspection ?owner ?ctx) -> table
;; summary: Evaluate registered introspection snapshots through the centralized pcall-isolated collector.
;; tags: extensions register introspection snapshots
(fn M.collect-introspection [?owner ?ctx]
  (introspect.collect ?owner ?ctx))

M
