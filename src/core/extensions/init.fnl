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

(local state (require :core.extensions.state))
(local util (require :core.extensions.util))
(local dispatch (require :core.extensions.dispatch))
(local registry (require :core.extensions.registry))
(local presenter (require :core.extensions.presenter))
(local introspection (require :core.extensions.introspection))

(local M {})

;; State table re-exports for tests/introspection. Identity lives in
;; core.extensions.state and survives reloads of this facade.
(set M.version state.version)
(set M.handlers state.handlers)
(set M.tools-extra state.tools-extra)
(set M.commands-extra state.commands-extra)
(set M.controls-extra state.controls-extra)
(set M.presenters state.presenters)
(set M.hooks state.hooks)
(set M.prompt-fragments state.prompt-fragments)
(set M.extensions state.extensions)
(set M.ui state.ui)

;; Runtime wrappers — each call resolves through the sub-module table at
;; call time so reloading dispatch/registry/presenter/introspection picks
;; up the new behavior even for callers that captured a reference to one
;; of these methods before the reload.
(fn M.emit [ev] (dispatch.emit ev))
(fn M.on [event-name handler ?owner] (dispatch.on event-name handler ?owner))
(fn M.dispatch-command [line caller-state]
  (dispatch.dispatch-command line caller-state))
(fn M.prompt [text-or-fn ?opts owner]
  (dispatch.contribute text-or-fn ?opts owner))
(fn M.fragments-for [slot] (dispatch.fragments-for slot))

(fn M.register [kind spec owner] (registry.register kind spec owner))
(fn M.merged-tools [base] (registry.merged-tools base))
(fn M.run-before-tool [tool-name args ctx]
  (registry.run-before-tool tool-name args ctx))
(fn M.unregister-by-owner [owner] (registry.unregister-by-owner owner))

(fn M.active-presenter [] (presenter.active-presenter))
(fn M.init-active-presenter [ctx] (presenter.init-active-presenter ctx))
(fn M.shutdown-active-presenter [ctx] (presenter.shutdown-active-presenter ctx))
(fn M.run-active-presenter [ctx] (presenter.run-active-presenter ctx))
(fn M.build-ui-slot [] (presenter.build-ui-slot))

(fn M.record-extension! [name rec] (introspection.record-extension! name rec))
(fn M.list [kind] (introspection.list kind))

(fn M.reset! []
  "Wipe all registries IN PLACE so identity references survive reset."
  (util.clear-table state.handlers)
  (util.clear-table state.tools-extra)
  (util.clear-table state.commands-extra)
  (util.clear-table (or state.controls-extra []))
  (set state.controls-extra (or state.controls-extra []))
  (util.clear-table state.presenters)
  (util.clear-table state.hooks.before-tool)
  (util.clear-table state.prompt-fragments.before-body)
  (util.clear-table state.prompt-fragments.before-context)
  (util.clear-table state.prompt-fragments.end)
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
