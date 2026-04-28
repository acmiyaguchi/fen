(local state (require :core.extensions.state))
(local util (require :core.extensions.util))

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

(fn M.register-presenter [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :presenter requires {:name ...}"))
  (let [tagged (util.deep-copy spec)]
    (tset tagged :__owner owner)
    (table.insert state.presenters tagged)
    (when (and tagged.active? (not state.ui.slot) tagged.ui)
      (set state.ui.slot tagged.ui))
    (handle-result :presenter spec.name owner
      (fn []
        (util.remove-where state.presenters (fn [p _] (= p tagged)))
        (when (= state.ui.slot tagged.ui)
          (M.promote-ui-slot!))))))

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

(fn M.init-active-presenter [ctx]
  (call-active-presenter :init ctx {:required? false}))

(fn M.shutdown-active-presenter [ctx]
  (call-active-presenter :shutdown ctx {:required? false}))

(fn M.run-active-presenter [ctx]
  (call-active-presenter :run ctx {:required? true}))

(local FALLBACKS
  {:notify (fn [text ?_opts]
             (io.stderr:write (.. (tostring text) "\n")))
   :prompt (fn [opts]
             (let [opts (or opts {})]
               (io.write (.. (tostring (or opts.label "?")) ": "))
               (io.flush)
               (io.read)))
   :select (fn [opts]
             (let [opts (or opts {})
                   choices (or opts.choices [])]
               (io.write (.. (tostring (or opts.label "?")) "\n"))
               (each [i c (ipairs choices)]
                 (io.write (.. "  " (tostring i) ". " (tostring c) "\n")))
               (io.write "> ")
               (io.flush)
               (let [line (io.read)
                     n (and line (tonumber line))]
                 (and n (>= n 1) (<= n (length choices)) (. choices n)))))})

(fn dispatch-ui [method ...]
  (if state.ui.slot
      ((. state.ui.slot method) ...)
      ((. FALLBACKS method) ...)))

(fn M.build-ui-slot []
  {:has-ui? (fn [] (not= state.ui.slot nil))
   :notify (fn [text opts] (dispatch-ui :notify text opts))
   :prompt (fn [opts] (dispatch-ui :prompt opts))
   :select (fn [opts] (dispatch-ui :select opts))})

M
