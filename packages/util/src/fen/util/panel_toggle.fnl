;; Visibility stays in each extension's persistent state module; this reloadable module only wires lifecycle.

(local subcommands (require :fen.util.subcommands))

(local M {})

(fn label [name] (tostring name))

(fn announce [api name visible?]
  (api.emit {:type :info
             :text (if visible?
                       (.. (label name) " panel: on (/" (label name)
                           " off or /" (label name) " to hide)")
                       (.. (label name) " panel: off"))}))

(fn set-visible! [api opts visible?]
  "Set visibility, dismiss competing panels before opening, invalidate only on
   change, and emit the standard panel announcement."
  (let [state opts.state]
    (when (not= state.visible? visible?)
      (when visible? (api.emit {:type :dismiss}))
      (set state.visible? visible?)
      (when opts.on-toggle (opts.on-toggle)))
    (announce api opts.name visible?)))

(fn M.install! [api opts]
  "opts requires :name, :command, :panel-spec, and persistent :state. Optional
   :on-toggle invalidates extension-owned render cache on visibility changes;
   :subcommands adds non-toggle command actions such as `/mem gc`; and
   :before-command receives the dispatcher run-state before command handling."
  (when (or (not opts) (not opts.name) (not opts.state)
            (not opts.command) (not opts.panel-spec))
    (error "panel-toggle.install! requires :name :command :panel-spec :state"))
  ;; Handlers close over module-private helpers; reload rewires them only when owners re-run install!.
  (let [command opts.command
        name opts.name
        toggle (fn [_args _run-state] (set-visible! api opts (not opts.state.visible?)))
        on (fn [_args _run-state] (set-visible! api opts true))
        off (fn [_args _run-state] (set-visible! api opts false))
        extras (or opts.subcommands {})
        toggle-subcommands {:on {:description "show the panel" :handler on}
                            :off {:description "hide the panel" :handler off}}
        _ (each [k v (pairs extras)] (tset toggle-subcommands k v))
        sub (subcommands.build
              {:name name
               :emit api.emit
               :summary (or command.description "Toggle the panel")
               :default toggle
               :subcommands toggle-subcommands})
        spec {}]
    (each [k v (pairs command)] (tset spec k v))
    (set spec.name (or command.name name))
    (set spec.usage (or command.usage sub.usage))
    (set spec.subcommands (or command.subcommands sub.descriptor))
    (set spec.complete (or command.complete sub.complete))
    (set spec.handler
         (fn [args run-state]
           (when opts.before-command (opts.before-command run-state))
           (sub.handler args run-state)))
    (api.register :command spec)
    (api.register :panel opts.panel-spec)
    (api.on :dismiss
            (fn [ev]
              (when opts.state.visible?
                (set opts.state.visible? false)
                (when opts.on-toggle (opts.on-toggle))
                (when ev.announce? (announce api opts.name false)))))))

M
