;; Extension API (issue #15, Step 1+ of v1 build order).
;;
;; This module is the api surface that extensions register against: tools,
;; commands, presenters, hooks, event subscriptions, and system-prompt
;; fragments. It also hosts the core-side helpers that consume those
;; registries: `merged-tools`, `fragments-for`, `run-before-tool`, and
;; `dispatch-command`. main.fnl wires the existing TUI/print presenters as
;; `:*` bus subscribers and routes `agent.on-event` through `extensions.emit`,
;; so events emitted from `core.agent` flow through this module on their way
;; to whoever's listening.
;;
;; State is stashed in `core.extensions_state` (NOT reloadable) so that
;; `/reload` can re-run THIS module's body — picking up edits to register
;; logic, dispatch behavior, system-prompt fragment rendering — without
;; clearing live subscriptions or registrations. This module IS reloadable;
;; the companion-state module is the one excluded from RELOADABLE.

(local state (require :core.extensions_state))
(local log (require :util.log))

(local M {})

;; Re-export the state tables so callers can access them via
;; `extensions.handlers` etc. (mostly tests). Identity is preserved across
;; reload because manual-reload!'s clear-and-copy puts state.X back into
;; the same field on the original module table.
(set M.version state.version)
(set M.handlers state.handlers)
(set M.tools-extra state.tools-extra)
(set M.commands-extra state.commands-extra)
(set M.presenters state.presenters)
(set M.hooks state.hooks)
(set M.prompt-fragments state.prompt-fragments)
(set M.extensions state.extensions)
(set M.ui state.ui)

;; -----------------------------------------------------------------
;; Helpers
;; -----------------------------------------------------------------

(fn deep-copy [v]
  (if (= (type v) :table)
      (let [out {}]
        (each [k vv (pairs v)]
          (tset out k (deep-copy vv)))
        out)
      v))

(fn freeze [t]
  "Read-only view: deep-copy then attach __newindex that errors on write.
   Cheap enough for the introspection api; not intended for hot paths."
  (let [copy (deep-copy t)]
    (when (= (type copy) :table)
      (setmetatable copy
                    {:__newindex
                     (fn [_ k _]
                       (error (.. "frozen: cannot set " (tostring k))))}))
    copy))

(fn remove-where [t pred]
  "Mutate `t` in place, dropping entries where `(pred entry index)` is true.
   Iterates back-to-front so removals don't shift unprocessed indices."
  (for [i (length t) 1 -1]
    (when (pred (. t i) i)
      (table.remove t i))))

(fn clear-table [t]
  (each [k _ (pairs t)] (tset t k nil)))

(fn append-handler [event-name entry]
  (let [bucket (or (. state.handlers event-name) [])]
    (table.insert bucket entry)
    (tset state.handlers event-name bucket)))

(fn remove-handler [event-name entry]
  (let [bucket (. state.handlers event-name)]
    (when bucket
      (remove-where bucket (fn [e _] (= e entry))))))

;; -----------------------------------------------------------------
;; Reset (test affordance)
;; -----------------------------------------------------------------

(fn M.record-extension! [name rec]
  "Record loader status for introspection. Loader-owned helper, not exposed on
   the public extension api."
  (tset state.extensions name rec)
  rec)

(fn M.reset! []
  "Wipe all registries IN PLACE so identity references survive reset.
   Tests call this in before_each."
  (clear-table state.handlers)
  (clear-table state.tools-extra)
  (clear-table state.commands-extra)
  (clear-table state.presenters)
  (clear-table state.hooks.before-tool)
  (clear-table state.prompt-fragments.before-body)
  (clear-table state.prompt-fragments.before-context)
  (clear-table state.prompt-fragments.end)
  (clear-table state.extensions)
  (set state.ui.slot nil)
  nil)

;; -----------------------------------------------------------------
;; Event bus
;; -----------------------------------------------------------------

(fn report-handler-error [entry ev err]
  "Surface extension event-handler failures without letting diagnostics recurse
   forever. A failing :extension-error handler is logged only."
  (let [event-type (?. ev :type)
        owner (or entry.owner :anonymous)
        msg (.. "extension handler failed"
                " owner=" (tostring owner)
                " event=" (tostring event-type)
                ": " (tostring err))]
    (log.warn msg)
    (when (not= event-type :extension-error)
      (M.emit {:type :extension-error
               :owner owner
               :event event-type
               :error (tostring err)}))))

(fn dispatch-bucket [bucket ev]
  (when bucket
    (each [_ entry (ipairs bucket)]
      ;; pcall isolation — one bad subscriber does not block siblings.
      ;; Failures are reported through logs and an :extension-error event
      ;; (with recursion protection in report-handler-error).
      (let [(ok? err) (pcall entry.fn ev)]
        (when (not ok?)
          (report-handler-error entry ev err))))))

(fn M.emit [ev]
  "Dispatch ev to handlers[ev.type] and the `:*` wildcard bucket. Each
   handler is pcall'd; one error does not block subsequent handlers."
  (when (and ev ev.type)
    (dispatch-bucket (. state.handlers ev.type) ev))
  (dispatch-bucket (. state.handlers :*) ev)
  nil)

(fn M.on [event-name handler ?owner]
  "Subscribe `handler` to `event-name` (`:*` for all events). Returns an
   unsubscribe function. Owner tag is optional and used by
   `unregister-by-owner` for per-extension teardown."
  (let [entry {:fn handler :owner ?owner}]
    (append-handler event-name entry)
    (fn [] (remove-handler event-name entry))))

;; -----------------------------------------------------------------
;; Registration
;; -----------------------------------------------------------------

(fn handle-result [kind name owner unregister]
  {: kind : name : owner : unregister})

(fn register-tool [spec owner]
  (when (or (not spec) (not spec.name))
    (error "register :tool requires {:name ...}"))
  (let [tagged (deep-copy spec)]
    (tset tagged :__owner owner)
    (table.insert state.tools-extra tagged)
    (handle-result :tool spec.name owner
      (fn []
        (remove-where state.tools-extra (fn [t _] (= t tagged)))))))

(fn register-command [spec owner]
  (when (or (not spec) (not spec.name) (not spec.handler))
    (error "register :command requires {:name :handler ...}"))
  (let [name spec.name
        record (deep-copy spec)]
    (tset record :owner owner)
    (when (. state.commands-extra name)
      ;; Last writer wins, with a (silent) overwrite — main loop emits a
      ;; warning via the bus once an `:extension-loaded` lifecycle event
      ;; exists. For now the loader-less Step 1 just overwrites.
      nil)
    (tset state.commands-extra name record)
    (handle-result :command name owner
      (fn []
        (when (= (?. state.commands-extra name :owner) owner)
          (tset state.commands-extra name nil))))))

(fn promote-ui-slot! []
  "Select the ui table from the first active presenter that supplies one.
   Conflict resolution is intentionally first-active-wins; later active
   presenters remain registered but inactive from the ui slot's point of view."
  (set state.ui.slot nil)
  (each [_ p (ipairs state.presenters)]
    (when (and (not state.ui.slot) p.active? p.ui)
      (set state.ui.slot p.ui))))

(fn active-presenter []
  "Return the first active presenter record, or nil when none registered."
  (var found nil)
  (each [_ p (ipairs state.presenters) &until found]
    (when p.active?
      (set found p)))
  found)

(fn register-presenter [spec owner]
  (when (or (not spec) (not spec.name))
    (error "register :presenter requires {:name ...}"))
  (let [tagged (deep-copy spec)]
    (tset tagged :__owner owner)
    (table.insert state.presenters tagged)
    (when (and tagged.active? (not state.ui.slot) tagged.ui)
      (set state.ui.slot tagged.ui))
    (handle-result :presenter spec.name owner
      (fn []
        (remove-where state.presenters (fn [p _] (= p tagged)))
        (when (= state.ui.slot tagged.ui)
          (promote-ui-slot!))))))

(fn register-hook [spec owner]
  (when (or (not spec) (not spec.before-tool))
    (error "register :hook requires {:before-tool fn} (v1 only phase)"))
  (let [entry {:fn spec.before-tool :owner owner}]
    (table.insert state.hooks.before-tool entry)
    (handle-result :hook :before-tool owner
      (fn []
        (remove-where state.hooks.before-tool
                      (fn [e _] (= e entry)))))))

(fn dispatch-register [kind spec owner]
  (if (= kind :tool) (register-tool spec owner)
      (= kind :command) (register-command spec owner)
      (= kind :presenter) (register-presenter spec owner)
      (= kind :hook) (register-hook spec owner)
      (error (.. "unknown register kind: " (tostring kind)))))

;; -----------------------------------------------------------------
;; System-prompt fragments
;; -----------------------------------------------------------------

(local PROMPT-SLOTS [:before-body :before-context :end])

(fn slot-valid? [slot]
  (var found false)
  (each [_ s (ipairs PROMPT-SLOTS)]
    (when (= s slot) (set found true)))
  found)

(fn contribute-system-prompt [text-or-fn ?opts owner]
  (let [opts (or ?opts {})
        slot (or opts.slot :end)]
    (when (not (slot-valid? slot))
      (error (.. "contribute-system-prompt: unknown slot " (tostring slot))))
    (let [bucket (. state.prompt-fragments slot)
          entry {:text-or-fn text-or-fn :owner owner}]
      (table.insert bucket entry)
      (handle-result :system-prompt-fragment slot owner
        (fn []
          (remove-where bucket (fn [e _] (= e entry))))))))

(fn render-fragment [entry]
  (let [val entry.text-or-fn]
    (if (= (type val) :function)
        (let [(ok? result) (pcall val)]
          (if ok?
              result
              (.. "<!-- extension "
                  (tostring entry.owner)
                  " failed: "
                  (tostring result)
                  " -->")))
        val)))

(fn M.fragments-for [slot]
  "Render registered fragments for `slot`. Returns nil when none are
   registered (so callers can skip the section entirely), otherwise a
   single string with `\\n\\n` between fragments."
  (let [bucket (. state.prompt-fragments slot)]
    (if (or (not bucket) (= (length bucket) 0))
        nil
        (let [parts []]
          (each [_ entry (ipairs bucket)]
            (let [rendered (render-fragment entry)]
              (when (and rendered (not= rendered ""))
                (table.insert parts (tostring rendered)))))
          (if (= (length parts) 0)
              nil
              (table.concat parts "\n\n"))))))

;; -----------------------------------------------------------------
;; Hooks
;; -----------------------------------------------------------------

(fn M.run-before-tool [tool-name args ctx]
  "Fire all :before-tool hooks. Returns {:block? :reason} when any hook
   returns `{:block true :reason ...}`; otherwise {:block? false}.
   First veto wins; remaining hooks for that call are skipped."
  (var blocked nil)
  (each [_ entry (ipairs state.hooks.before-tool) &until blocked]
    (let [(ok? result) (pcall entry.fn tool-name args ctx)]
      (when (and ok? (= (type result) :table) result.block)
        (set blocked {:block? true :reason result.reason}))))
  (or blocked {:block? false}))

;; -----------------------------------------------------------------
;; Tools merge for the agent loop
;; -----------------------------------------------------------------

(fn M.merged-tools [base]
  "Return base ++ extension-contributed tools. New table on every call so
   downstream mutation does not leak into the base list."
  (let [out []]
    (each [_ t (ipairs (or base []))] (table.insert out t))
    (each [_ t (ipairs state.tools-extra)] (table.insert out t))
    out))

;; -----------------------------------------------------------------
;; Per-owner teardown
;; -----------------------------------------------------------------

(fn M.unregister-by-owner [owner]
  "Drop every registration tagged with `owner`. Used by the (future)
   loader for `/reload-extension`."
  (remove-where state.tools-extra
                (fn [t _] (= t.__owner owner)))
  (each [name rec (pairs state.commands-extra)]
    (when (= rec.owner owner)
      (tset state.commands-extra name nil)))
  (remove-where state.presenters
                (fn [p _] (= p.__owner owner)))
  (promote-ui-slot!)
  (remove-where state.hooks.before-tool
                (fn [e _] (= e.owner owner)))
  (each [_ slot (ipairs PROMPT-SLOTS)]
    (remove-where (. state.prompt-fragments slot)
                  (fn [e _] (= e.owner owner))))
  (each [event-name bucket (pairs state.handlers)]
    (remove-where bucket (fn [e _] (= e.owner owner))))
  (tset state.extensions owner nil)
  nil)

;; -----------------------------------------------------------------
;; Slash command dispatch
;; -----------------------------------------------------------------

(fn parse-slash [line]
  "Split `/foo bar baz` into (\"foo\", \"bar baz\"). Returns nil for the name
   when the line is not a slash command."
  (let [stripped (string.match line "^/(.*)$")]
    (if (or (not stripped) (= stripped ""))
        (values nil "")
        (let [space-idx (string.find stripped "%s")]
          (if space-idx
              (values (string.sub stripped 1 (- space-idx 1))
                      (string.sub stripped (+ space-idx 1)))
              (values stripped ""))))))

(fn M.dispatch-command [line caller-state]
  "Look up a registered command by parsing `/name args` from `line`, gate
   `:idle-only?` while the agent is busy, and pcall-isolate the handler so
   a buggy command does not crash the loop. Errors surface as `:error`
   bus events. Built-in handlers register from core.builtin_commands;
   extension handlers register from anywhere via api.register :command."
  (let [(name args) (parse-slash line)]
    (if (not name)
        (M.emit {:type :error :error "empty command (try /help)"})
        (let [rec (. state.commands-extra name)]
          (if (not rec)
              (M.emit {:type :error
                       :error (.. "unknown command: /" name " (try /help)")})
              (and rec.idle-only? caller-state.busy?)
              (M.emit {:type :error
                       :error (.. "/" name
                                  " is disabled while the agent is running")})
              (let [(ok? err) (pcall rec.handler args caller-state)]
                (when (not ok?)
                  (M.emit {:type :error
                           :error (.. "/" name ": " (tostring err))}))))))))

;; -----------------------------------------------------------------
;; Presenter lifecycle
;; -----------------------------------------------------------------

(fn M.active-presenter []
  "Return the active presenter record, or nil when no presenter is active.
   This is the live registry record (not a frozen introspection copy), for
   core-side lifecycle dispatch only. Extensions should use `api.list` for
   read-only introspection."
  (active-presenter))

(fn call-active-presenter [method ctx opts]
  (let [p (active-presenter)
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
  "Run the active presenter's optional `:init` lifecycle method."
  (call-active-presenter :init ctx {:required? false}))

(fn M.shutdown-active-presenter [ctx]
  "Run the active presenter's optional `:shutdown` lifecycle method."
  (call-active-presenter :shutdown ctx {:required? false}))

(fn M.run-active-presenter [ctx]
  "Run the active presenter's required `:run` lifecycle method."
  (call-active-presenter :run ctx {:required? true}))

;; -----------------------------------------------------------------
;; UI slot
;; -----------------------------------------------------------------

(fn fallback-notify [text ?_opts]
  (io.stderr:write (.. (tostring text) "\n")))

(fn fallback-prompt [opts]
  (let [opts (or opts {})]
    (io.write (.. (tostring (or opts.label "?")) ": "))
    (io.flush)
    (io.read)))

(fn fallback-select [opts]
  (let [opts (or opts {})
        choices (or opts.choices [])]
    (io.write (.. (tostring (or opts.label "?")) "\n"))
    (each [i c (ipairs choices)]
      (io.write (.. "  " (tostring i) ". " (tostring c) "\n")))
    (io.write "> ")
    (io.flush)
    (let [line (io.read)
          n (and line (tonumber line))]
      (and n (>= n 1) (<= n (length choices)) (. choices n)))))

(fn build-ui-slot []
  ;; Each call resolves through state.ui.slot so a presenter that
  ;; registers later in the session takes effect immediately.
  {:has-ui? (fn [] (not= state.ui.slot nil))
   :notify (fn [text opts]
             (if state.ui.slot
                 (state.ui.slot.notify text opts)
                 (fallback-notify text opts)))
   :prompt (fn [opts]
             (if state.ui.slot
                 (state.ui.slot.prompt opts)
                 (fallback-prompt opts)))
   :select (fn [opts]
             (if state.ui.slot
                 (state.ui.slot.select opts)
                 (fallback-select opts)))})

;; -----------------------------------------------------------------
;; Introspection
;; -----------------------------------------------------------------

(fn list-event-handlers []
  (let [out {}]
    (each [event-name bucket (pairs state.handlers)]
      (let [entries []]
        (each [_ e (ipairs bucket)]
          (table.insert entries {:owner e.owner}))
        (tset out event-name entries)))
    out))

(fn list-prompt-contributions []
  (let [out {}]
    (each [_ slot (ipairs PROMPT-SLOTS)]
      (let [bucket (. state.prompt-fragments slot)
            entries []]
        (each [_ e (ipairs bucket)]
          (table.insert entries {:owner e.owner
                                 :dynamic? (= (type e.text-or-fn) :function)}))
        (tset out slot entries)))
    out))

(fn list-tools []
  (let [out []]
    (each [_ t (ipairs state.tools-extra)]
      (table.insert out {:name t.name :owner t.__owner}))
    out))

(fn list-commands []
  (let [out []]
    (each [name rec (pairs state.commands-extra)]
      (table.insert out {:name name :owner rec.owner
                         :description rec.description}))
    out))

(fn list-presenters []
  (let [out []]
    (each [_ p (ipairs state.presenters)]
      (table.insert out {:name p.name :owner p.__owner :active? p.active?
                         :has-init? (= (type p.init) :function)
                         :has-run? (= (type p.run) :function)
                         :has-shutdown? (= (type p.shutdown) :function)}))
    out))

(fn list-extensions []
  (let [out []]
    (each [name rec (pairs state.extensions)]
      (table.insert out {:name name :status rec.status :path rec.path
                         :first-party? rec.first-party?}))
    out))

(fn M.list [kind]
  (let [data (if (= kind :tools) (list-tools)
                 (= kind :commands) (list-commands)
                 (= kind :presenters) (list-presenters)
                 (= kind :extensions) (list-extensions)
                 (= kind :event-handlers) (list-event-handlers)
                 (= kind :system-prompt-contributions) (list-prompt-contributions)
                 (error (.. "unknown list kind: " (tostring kind))))]
    (freeze data)))

(fn M.describe-extension [name]
  (let [rec (. state.extensions name)]
    (if rec (freeze rec) nil)))

;; -----------------------------------------------------------------
;; Per-extension api factory
;; -----------------------------------------------------------------

(fn M.make-api [owner ?manifest]
  "Return the api table handed to an extension's `register` function.
   `owner` tags every contribution so unregister-by-owner can clean up.
   `?manifest` is captured in state.extensions for introspection.
   The api's methods resolve through M (the module table) at call time
   so extensions held past a /reload pick up new behavior."
  (when (and owner ?manifest)
    (tset state.extensions owner
          {:manifest ?manifest :status :loaded :owner owner}))
  {:version state.version
   :register (fn [kind spec] (dispatch-register kind spec owner))
   :on (fn [event-name handler] (M.on event-name handler owner))
   :emit (fn [ev] (M.emit ev))
   :contribute-system-prompt
     (fn [text-or-fn ?opts]
       (contribute-system-prompt text-or-fn ?opts owner))
   :list (fn [kind] (M.list kind))
   :describe-extension (fn [name] (M.describe-extension name))
   :ui (build-ui-slot)})

M
