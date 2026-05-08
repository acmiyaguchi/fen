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
(local prompt (require :fen.core.extensions.register.prompt))
(local presenter (require :fen.core.extensions.register.presenter))
(local introspect (require :fen.core.extensions.register.introspect))
(local provider (require :fen.core.extensions.register.provider))
(local auth-backend (require :fen.core.extensions.register.auth_backend))
(local session-backend (require :fen.core.extensions.register.session_backend))

(local M {})

(fn handle-result [kind name owner unregister]
  {: kind : name : owner : unregister})

;; @doc fen.core.extensions.register.register
;; kind: function
;; signature: (register kind spec owner) -> register-result
;; summary: Dispatch one extension contribution to the per-kind registry module and return its owner-tagged unregister handle.
;; tags: extensions register dispatcher
(fn M.register [kind spec owner]
  (if (= kind :tool) (tool.register spec owner handle-result)
      (= kind :command) (command.register spec owner handle-result)
      (= kind :control) (control.register spec owner handle-result)
      (= kind :status) (status.register spec owner handle-result)
      (= kind :panel) (panel.register spec owner handle-result)
      (= kind :hook) (hook.register spec owner handle-result)
      (= kind :presenter) (presenter.register spec owner handle-result)
      (= kind :introspect) (introspect.register spec owner handle-result)
      (= kind :provider) (provider.register spec owner handle-result)
      (= kind :auth-backend) (auth-backend.register spec owner handle-result)
      (= kind :session-backend) (session-backend.register spec owner handle-result)
      (error (.. "unknown register kind: " (tostring kind)))))

;; @doc fen.core.extensions.register.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Sweep every registry kind and event-handler bucket, removing contributions tagged with owner during reload or teardown.
;; tags: extensions register reload
(fn M.unregister-by-owner [owner]
  "Drop every registration tagged with owner."
  (tool.unregister-by-owner owner)
  (command.unregister-by-owner owner)
  (control.unregister-by-owner owner)
  (status.unregister-by-owner owner)
  (panel.unregister-by-owner owner)
  (presenter.unregister-by-owner owner)
  (introspect.unregister-by-owner owner)
  (provider.unregister-by-owner owner)
  (auth-backend.unregister-by-owner owner)
  (session-backend.unregister-by-owner owner)
  (hook.unregister-by-owner owner)
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

;; @doc fen.core.extensions.register.list
;; kind: function
;; signature: (list kind) -> frozen-table
;; summary: Return a frozen introspection list for the requested registry kind, including extensions, event handlers, and prompt fragments.
;; tags: extensions register introspection
(fn M.list [kind]
  (let [data (if (= kind :tools) (tool.list)
                 (= kind :commands) (command.list)
                 (= kind :controls) (control.list)
                 (= kind :status) (status.list)
                 (= kind :panels) (panel.list)
                 (= kind :presenters) (presenter.list)
                 (= kind :introspectors) (introspect.list)
                 (= kind :providers) (provider.list)
                 (= kind :auth-backends) (auth-backend.list)
                 (= kind :session-backends) (session-backend.list)
                 (= kind :extensions) (list-extensions)
                 (= kind :event-handlers) (events.list)
                 (= kind :prompt-fragments) (prompt.list)
                 (error (.. "unknown list kind: " (tostring kind))))]
    (util.freeze data)))

;; @doc fen.core.extensions.register.collect-introspection
;; kind: function
;; signature: (collect-introspection ?owner ?ctx) -> table
;; summary: Evaluate registered introspection snapshots through the centralized pcall-isolated collector.
;; tags: extensions register introspection snapshots
(fn M.collect-introspection [?owner ?ctx]
  (introspect.collect ?owner ?ctx))

M
