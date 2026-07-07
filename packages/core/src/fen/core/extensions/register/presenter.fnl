;; Presenter kind. Slightly larger than the others because presenters carry an
;; init/run/shutdown lifecycle and can install a UI slot used by the rest of
;; the system.
;;
;; Public extension-facing surface: `build-ui-slot` is what `api.ui` wraps
;; (`has-ui?`, `notify`, `prompt`, `select` — see docs/extensions.md).
;; Everything else in this module (promote-ui-slot!, active-presenter,
;; register, unregister-by-owner, init/run/shutdown-active-presenter, list)
;; is core runtime plumbing used by the loader and `fen.core.extensions`,
;; not part of the extension api contract.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

;; @doc fen.core.extensions.register.presenter.promote-ui-slot!
;; kind: function
;; signature: (promote-ui-slot!) -> nil
;; summary: Recompute the shared UI slot from the first active presenter that supplies one after unregister or reload.
;; tags: extensions presenter ui reload
(fn M.promote-ui-slot! []
  "Select the ui table from the first active presenter that supplies one."
  (set state.ui.slot nil)
  (each [_ p (ipairs state.presenters)]
    (when (and (not state.ui.slot) p.active? p.ui)
      (set state.ui.slot p.ui))))

;; @doc fen.core.extensions.register.presenter.active-presenter
;; kind: function
;; signature: (active-presenter) -> Presenter|nil
;; summary: Return the first registered presenter marked active, or nil when no presenter has claimed the run.
;; tags: extensions presenter ui
(fn M.active-presenter []
  "Return the first active presenter record, or nil."
  (var found nil)
  (each [_ p (ipairs state.presenters) &until found]
    (when p.active?
      (set found p)))
  found)

;; @doc fen.core.extensions.register.presenter.register
;; kind: function
;; signature: (register spec owner handle-result) -> register-result
;; summary: Validate and append a presenter contribution, promoting its UI slot immediately when it is active.
;; tags: extensions register presenter ui
(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :presenter requires {:name ...}"))
  (let [(tagged unregister) (util.add-tagged! state.presenters spec owner)]
    (when (and tagged.active? (not state.ui.slot) tagged.ui)
      (set state.ui.slot tagged.ui))
    (handle-result :presenter spec.name owner
      (fn []
        (unregister)
        (when (= state.ui.slot tagged.ui)
          (M.promote-ui-slot!))))))

;; @doc fen.core.extensions.register.presenter.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Remove presenters installed by owner and promote the next active UI slot so extension APIs keep working after reload.
;; tags: extensions presenter reload
(fn M.unregister-by-owner [owner]
  (util.remove-where state.presenters
                     (fn [p _] (= p.__owner owner)))
  (M.promote-ui-slot!))

(fn call-active-presenter [method ctx opts]
  (let [p (M.active-presenter)
        opts (or opts {})]
    (if (not p)
        (values false "no active presenter registered")
        (let [f (. p method)]
          (if (= (type f) :function)
              (pcall f ctx)
              opts.required?
              (values false (.. "active presenter " (tostring p.name)
                                " has no " (tostring method) " method"))
              (values true nil))))))

;; @doc fen.core.extensions.register.presenter.init-active-presenter
;; kind: function
;; signature: (init-active-presenter ctx) -> ok?, result
;; summary: Call the active presenter's optional :init lifecycle method through a pcall-style result pair.
;; tags: extensions presenter lifecycle
(fn M.init-active-presenter [ctx]
  (call-active-presenter :init ctx {:required? false}))

;; @doc fen.core.extensions.register.presenter.shutdown-active-presenter
;; kind: function
;; signature: (shutdown-active-presenter ctx) -> ok?, result
;; summary: Call the active presenter's optional :shutdown lifecycle method during process teardown.
;; tags: extensions presenter lifecycle
(fn M.shutdown-active-presenter [ctx]
  (call-active-presenter :shutdown ctx {:required? false}))

;; @doc fen.core.extensions.register.presenter.run-active-presenter
;; kind: function
;; signature: (run-active-presenter ctx) -> ok?, result
;; summary: Call the active presenter's required :run lifecycle method and report an error pair when no runnable presenter exists.
;; tags: extensions presenter lifecycle
(fn M.run-active-presenter [ctx]
  (call-active-presenter :run ctx {:required? true}))

;; Fallbacks run only when api.ui is called with no active presenter (for
;; example a headless run, or an extension that skipped api.ui.has-ui?).
;; notify degrades to a plain stderr line so the message is not lost.
;; prompt/select have no non-interactive answer to give, so they log to
;; stderr and return nil rather than silently blocking on stdin — callers
;; should check api.ui.has-ui? first, or treat a nil result as "no UI".
(local FALLBACKS
  {:notify (fn [text ?_opts]
             (io.stderr:write (.. (tostring text) "\n")))
   :prompt (fn [opts]
             (let [opts (or opts {})]
               (io.stderr:write
                 (.. "fen: api.ui.prompt called with no active presenter"
                    " (label: " (tostring (or opts.label "?"))
                    "); returning nil\n"))
               nil))
   :select (fn [opts]
             (let [opts (or opts {})]
               (io.stderr:write
                 (.. "fen: api.ui.select called with no active presenter"
                    " (label: " (tostring (or opts.label "?"))
                    "); returning nil\n"))
               nil))})

(fn dispatch-ui [method ...]
  (if state.ui.slot
      ((. state.ui.slot method) ...)
      ((. FALLBACKS method) ...)))

;; @doc fen.core.extensions.register.presenter.build-ui-slot
;; kind: function
;; signature: (build-ui-slot) -> table
;; summary: Build the stable extension-facing UI facade whose methods dispatch to the active presenter or lightweight fallbacks.
;; tags: extensions presenter ui api
(fn M.build-ui-slot []
  {:has-ui? (fn [] (not= state.ui.slot nil))
   :notify (fn [text opts] (dispatch-ui :notify text opts))
   :prompt (fn [opts] (dispatch-ui :prompt opts))
   :select (fn [opts] (dispatch-ui :select opts))})

;; @doc fen.core.extensions.register.presenter.list
;; kind: function
;; signature: (list) -> [PresenterInfo]
;; summary: Return presenter metadata and lifecycle capability flags for diagnostics and runtime docs.
;; tags: extensions presenter introspection
(fn M.list []
  (let [out []]
    (each [_ p (ipairs state.presenters)]
      (table.insert out {:name p.name :owner p.__owner :active? p.active?
                         :has-init? (= (type p.init) :function)
                         :has-run? (= (type p.run) :function)
                         :has-shutdown? (= (type p.shutdown) :function)}))
    out))

M
