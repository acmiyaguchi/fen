;; Extension-facing API facade.
;;
;; Stable public extension API is only the table returned by make-api:
;;   version, register, on, emit, prompt, list, ui
;;
;; The other exports on this module are core runtime plumbing for main.fnl,
;; tests, and bundled first-party extensions. They are intentionally available
;; in-process but are not part of the third-party extension contract.
;;
;; All exported methods wrap the underlying sub-module function in a closure
;; that resolves through the sub-module table at call time. This is the
;; reload contract: when a sub-module reloads, prior captures of its
;; functions stay valid because every call goes through the (mutated)
;; module table.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))
(local events (require :fen.core.extensions.events))
(local register (require :fen.core.extensions.register))

(local M {})

;; State table re-exports for tests/introspection. Identity lives in
;; core.extensions.state and survives reloads of this facade.
(set M.version state.version)
(set M.handlers state.handlers)
(set M.tools-extra state.tools-extra)
(set M.commands-extra state.commands-extra)
(set M.controls-extra state.controls-extra)
(set M.status-extra state.status-extra)
(set M.presenters state.presenters)
(set M.providers state.providers)
(set M.auth-backends state.auth-backends)
(set M.session-backends state.session-backends)
(set M.session state.session)
(set M.hooks state.hooks)
(set M.extensions state.extensions)
(set M.ui state.ui)

;; Runtime wrappers — each call resolves through the sub-module table at
;; call time so reloading events / register sub-modules picks up the new
;; behavior even for callers that captured a reference to one of these
;; methods before the reload.
(fn M.emit [ev] (events.emit ev))
(fn M.on [event-name handler ?owner] (events.on event-name handler ?owner))

(fn M.register [kind spec owner] (register.register kind spec owner))
(fn M.dispatch-command [line caller-state]
  (register.dispatch-command line caller-state))
(fn M.prompt [text-or-fn ?opts owner]
  (register.contribute text-or-fn ?opts owner))
(fn M.render-prompt [ctx] (register.render-prompt ctx))
(fn M.merged-tools [base] (register.merged-tools base))
(fn M.run-before-tool [tool-name args ctx]
  (register.run-before-tool tool-name args ctx))
(fn M.unregister-by-owner [owner] (register.unregister-by-owner owner))
(fn M.list [kind] (register.list kind))

(fn M.active-presenter [] (register.active-presenter))
(fn M.init-active-presenter [ctx] (register.init-active-presenter ctx))
(fn M.shutdown-active-presenter [ctx] (register.shutdown-active-presenter ctx))
(fn M.run-active-presenter [ctx] (register.run-active-presenter ctx))
(fn M.build-ui-slot [] (register.build-ui-slot))
(fn M.find-provider [name] (register.find-provider name))
(fn M.find-provider-by-api [api] (register.find-provider-by-api api))
(fn M.list-providers-by-api [api] (register.list-providers-by-api api))
(fn M.find-auth-backend [name] (register.find-auth-backend name))
(fn M.find-session-backend [name] (register.find-session-backend name))
(fn M.set-active-session-backend! [name]
  (register.set-active-session-backend! name))
(fn M.active-session-backend [] (register.active-session-backend))
(fn M.set-session-info! [info] (register.set-session-info! info))
(fn M.session-info [] (register.session-info))

(fn M.record-extension! [name rec]
  "Record loader status for introspection."
  (tset state.extensions name rec)
  rec)

(fn M.reset! []
  "Wipe all registries IN PLACE so identity references survive reset."
  (util.clear-table state.handlers)
  (util.clear-table state.tools-extra)
  (util.clear-table state.commands-extra)
  (util.clear-table state.controls-extra)
  (when (= state.status-extra nil) (set state.status-extra []))
  (util.clear-table state.status-extra)
  (when (= state.panel-extra nil) (set state.panel-extra []))
  (util.clear-table state.panel-extra)
  (util.clear-table state.presenters)
  (when (= state.providers nil) (set state.providers {}))
  (util.clear-table state.providers)
  (when (= state.auth-backends nil) (set state.auth-backends {}))
  (util.clear-table state.auth-backends)
  (when (= state.session-backends nil) (set state.session-backends {}))
  (util.clear-table state.session-backends)
  (when (= state.session nil)
    (set state.session {:active-name nil :backend nil :info nil}))
  (set state.session.active-name nil)
  (set state.session.backend nil)
  (set state.session.info nil)
  (util.clear-table state.hooks.before-tool)
  (util.clear-table state.prompt-fragments)
  (set state.prompt-next-seq 0)
  (util.clear-table state.extensions)
  (set state.ui.slot nil)
  nil)

(fn M.make-api [owner ?manifest]
  "Return the small stable api table handed to an extension's register function."
  (when (and owner ?manifest)
    (tset state.extensions owner
          {:manifest ?manifest :status :loaded :owner owner}))
  {:version state.version
   :register (fn [kind spec] (M.register kind spec owner))
   :on (fn [event-name handler] (M.on event-name handler owner))
   :emit (fn [ev] (M.emit ev))
   :prompt (fn [text-or-fn ?opts]
             (M.prompt text-or-fn ?opts owner))
   :list (fn [kind] (M.list kind))
   :ui (M.build-ui-slot)})

M
