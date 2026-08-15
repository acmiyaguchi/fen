;; Presenter kind. Only `build-ui-slot` is extension-facing (via api.ui); the rest is core plumbing.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

(fn M.promote-ui-slot! []
  "Select the ui table from the first active presenter that supplies one."
  (set state.ui.slot nil)
  (each [_ p (ipairs state.presenters)]
    (when (and (not state.ui.slot) p.active? p.ui)
      (set state.ui.slot p.ui))))

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

;; No-presenter fallbacks: prompt/select log to stderr and return nil rather than block on stdin.
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
                         :idle-ticks? (not (not p.idle-ticks?))
                         :has-init? (= (type p.init) :function)
                         :has-run? (= (type p.run) :function)
                         :has-shutdown? (= (type p.shutdown) :function)}))
    out))

M
