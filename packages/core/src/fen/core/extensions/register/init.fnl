;; Kind dispatcher for `api.register :foo ...` plus the cross-cutting
;; sweeps and lookups that touch every kind (unregister-by-owner, list).
;;
;; Each per-kind file owns: register, unregister-by-owner, list, and any
;; verbs unique to that kind (run/dispatch/render). This module wires them
;; together through closures that resolve through each sub-module's table at
;; call time, so reloads of the per-kind files take effect immediately.
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
                 (= kind :providers) (provider.list)
                 (= kind :auth-backends) (auth-backend.list)
                 (= kind :session-backends) (session-backend.list)
                 (= kind :extensions) (list-extensions)
                 (= kind :event-handlers) (events.list)
                 (= kind :prompt-fragments) (prompt.list)
                 (error (.. "unknown list kind: " (tostring kind))))]
    (util.freeze data)))

;; Cross-module wrappers — call-time resolution through each sub-module
;; table so reloads pick up new behavior.
;; @doc fen.core.extensions.register.merged-tools
;; kind: function
;; signature: (merged-tools base) -> [AgentTool]
;; summary: Return base tools plus extension-contributed tools by delegating to the tool registry at call time.
;; tags: extensions tools reload
(fn M.merged-tools [base] (tool.merged base))

;; @doc fen.core.extensions.register.run-before-tool
;; kind: function
;; signature: (run-before-tool tool-name args ctx) -> hook-decision
;; summary: Run before-tool hooks through the hook registry and return the first blocking decision or non-blocking result.
;; tags: extensions hooks tools
(fn M.run-before-tool [tool-name args ctx]
  (hook.run-before-tool tool-name args ctx))

;; @doc fen.core.extensions.register.dispatch-command
;; kind: function
;; signature: (dispatch-command line caller-state) -> nil
;; summary: Dispatch a slash command through the command registry while preserving reload-safe module indirection.
;; tags: extensions commands reload
(fn M.dispatch-command [line caller-state]
  (command.dispatch line caller-state))

;; @doc fen.core.extensions.register.contribute
;; kind: function
;; signature: (contribute text-or-fn ?opts owner) -> register-result
;; summary: Contribute a prompt fragment through the prompt registry, using the same result shape as api.register.
;; tags: extensions prompt register
(fn M.contribute [text-or-fn ?opts owner]
  (prompt.contribute text-or-fn ?opts owner handle-result))

;; @doc fen.core.extensions.register.render-prompt
;; kind: function
;; signature: (render-prompt ctx) -> string|nil
;; summary: Render system-prompt fragments through the prompt registry with call-time indirection for reload safety.
;; tags: extensions prompt reload
(fn M.render-prompt [ctx] (prompt.render ctx))

;; @doc fen.core.extensions.register.active-presenter
;; kind: function
;; signature: (active-presenter) -> Presenter|nil
;; summary: Return the active presenter via the presenter registry facade.
;; tags: extensions presenter ui
(fn M.active-presenter [] (presenter.active-presenter))

;; @doc fen.core.extensions.register.init-active-presenter
;; kind: function
;; signature: (init-active-presenter ctx) -> ok?, result
;; summary: Initialize the active presenter through the presenter registry facade.
;; tags: extensions presenter lifecycle
(fn M.init-active-presenter [ctx] (presenter.init-active-presenter ctx))

;; @doc fen.core.extensions.register.shutdown-active-presenter
;; kind: function
;; signature: (shutdown-active-presenter ctx) -> ok?, result
;; summary: Shut down the active presenter through the presenter registry facade.
;; tags: extensions presenter lifecycle
(fn M.shutdown-active-presenter [ctx] (presenter.shutdown-active-presenter ctx))

;; @doc fen.core.extensions.register.run-active-presenter
;; kind: function
;; signature: (run-active-presenter ctx) -> ok?, result
;; summary: Run the active presenter's main loop through the presenter registry facade.
;; tags: extensions presenter lifecycle
(fn M.run-active-presenter [ctx] (presenter.run-active-presenter ctx))

;; @doc fen.core.extensions.register.build-ui-slot
;; kind: function
;; signature: (build-ui-slot) -> table
;; summary: Build the stable extension-facing UI slot through the presenter registry facade.
;; tags: extensions presenter ui
(fn M.build-ui-slot [] (presenter.build-ui-slot))

;; @doc fen.core.extensions.register.find-provider
;; kind: function
;; signature: (find-provider name) -> Provider|nil
;; summary: Resolve a provider by unique registry name through the provider registry facade.
;; tags: extensions providers lookup
(fn M.find-provider [name] (provider.find name))

;; @doc fen.core.extensions.register.find-provider-by-api
;; kind: function
;; signature: (find-provider-by-api api) -> Provider|nil
;; summary: Resolve the first provider for an api family through the provider registry facade.
;; tags: extensions providers lookup
(fn M.find-provider-by-api [api] (provider.find-by-api api))

;; @doc fen.core.extensions.register.list-providers-by-api
;; kind: function
;; signature: (list-providers-by-api api) -> [Provider]
;; summary: List providers for an api family through the provider registry facade.
;; tags: extensions providers lookup
(fn M.list-providers-by-api [api] (provider.list-by-api api))

;; @doc fen.core.extensions.register.find-auth-backend
;; kind: function
;; signature: (find-auth-backend name) -> AuthBackend|nil
;; summary: Resolve an auth backend by name through the auth-backend registry facade.
;; tags: extensions auth lookup
(fn M.find-auth-backend [name] (auth-backend.find name))

;; @doc fen.core.extensions.register.find-session-backend
;; kind: function
;; signature: (find-session-backend name) -> SessionBackend|nil
;; summary: Resolve a session backend by name through the session-backend registry facade.
;; tags: extensions session lookup
(fn M.find-session-backend [name] (session-backend.find name))

;; @doc fen.core.extensions.register.set-active-session-backend!
;; kind: function
;; signature: (set-active-session-backend! name) -> SessionBackend|nil
;; summary: Set the active session backend through the session-backend registry facade.
;; tags: extensions session state
(fn M.set-active-session-backend! [name] (session-backend.set-active! name))

;; @doc fen.core.extensions.register.active-session-backend
;; kind: function
;; signature: (active-session-backend) -> SessionBackend|nil
;; summary: Return the active session backend through the session-backend registry facade.
;; tags: extensions session state
(fn M.active-session-backend [] (session-backend.active))

;; @doc fen.core.extensions.register.set-session-info!
;; kind: function
;; signature: (set-session-info! info) -> info
;; summary: Store active session metadata through the session-backend registry facade.
;; tags: extensions session introspection
(fn M.set-session-info! [info] (session-backend.set-info! info))

;; @doc fen.core.extensions.register.session-info
;; kind: function
;; signature: (session-info) -> SessionInfo|nil
;; summary: Return cached active session metadata through the session-backend registry facade.
;; tags: extensions session introspection
(fn M.session-info [] (session-backend.info))

M
