;; Extension-facing API facade.
;;
;; Stable public extension API is only the table returned by make-api:
;;   version, register, on, emit, prompt, list, ui
;;
;; The other exports on this module are core runtime plumbing for main.fnl,
;; tests, and bundled first-party extensions. They are intentionally available
;; in-process but are not part of the third-party extension contract.

(local state (require :core.extensions.state))
(local runtime (require :core.extensions.runtime))

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

;; Runtime wrapper exports. Keep these as functions allocated by this module so
;; reloading core.extensions updates module-table function identities while each
;; call resolves through the reloadable runtime facade.
(fn M.emit [ev] (runtime.emit ev))
(fn M.on [event-name handler ?owner] (runtime.on event-name handler ?owner))
(fn M.register [kind spec owner] (runtime.register kind spec owner))
(fn M.merged-tools [base] (runtime.merged-tools base))
(fn M.run-before-tool [tool-name args ctx]
  (runtime.run-before-tool tool-name args ctx))
(fn M.unregister-by-owner [owner] (runtime.unregister-by-owner owner))
(fn M.dispatch-command [line caller-state]
  (runtime.dispatch-command line caller-state))
(fn M.prompt [text-or-fn ?opts owner]
  (runtime.prompt text-or-fn ?opts owner))
(fn M.fragments-for [slot] (runtime.fragments-for slot))
(fn M.active-presenter [] (runtime.active-presenter))
(fn M.init-active-presenter [ctx] (runtime.init-active-presenter ctx))
(fn M.shutdown-active-presenter [ctx] (runtime.shutdown-active-presenter ctx))
(fn M.run-active-presenter [ctx] (runtime.run-active-presenter ctx))
(fn M.build-ui-slot [] (runtime.build-ui-slot))
(fn M.record-extension! [name rec] (runtime.record-extension! name rec))
(fn M.list [kind] (runtime.list kind))
(fn M.reset! [] (runtime.reset!))

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
