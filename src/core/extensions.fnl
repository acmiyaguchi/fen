;; Extension API skeleton (issue #15, Step 1 of v1 build order).
;;
;; This module hosts the api surface that future extensions register against:
;; tools, commands, presenters, hooks, event subscriptions, and system-prompt
;; fragments. With no extensions loaded the api is inert — its presence does
;; not change observable behavior. main.fnl wires the existing TUI/print
;; presenters as `:*` bus subscribers and routes `agent.on-event` through
;; `extensions.emit`, so events emitted from `core.agent` flow through this
;; module on their way to whoever's listening.
;;
;; State (handlers, contributions) lives on the module table itself so it
;; survives `/reload`. main.fnl deliberately omits `core.extensions` from
;; RELOADABLE — same trick `tui.state` uses (see src/tui/state.fnl). Logic
;; changes to this file therefore require a process restart, but bus
;; subscriptions made by long-lived presenters (the TUI) survive.

(local M {})

(set M.version 1)

;; -----------------------------------------------------------------
;; State
;; -----------------------------------------------------------------

;; Mutable registries. Reset by `M.reset!` (used by tests) and individually
;; trimmed by `M.unregister-by-owner` (used by the future loader on
;; per-extension reload).
(set M.handlers {})            ; { event-name [{:fn :owner}], "*" [...] }
(set M.tools-extra [])         ; tools contributed via api.register :tool
(set M.commands-extra {})      ; { name {:description :handler :owner} }
(set M.presenters [])          ; presenter records, possibly with :ui slot
(set M.hooks {:before-tool []}) ; v1 only one phase
(set M.prompt-fragments {:before-body []
                         :before-context []
                         :end []})
(set M.extensions {})          ; { name {:manifest :status :owner} }
(set M.ui-slot nil)            ; first presenter's :ui table wins

(fn M.reset! []
  "Wipe all registries. Tests call this in before_each."
  (set M.handlers {})
  (set M.tools-extra [])
  (set M.commands-extra {})
  (set M.presenters [])
  (set M.hooks {:before-tool []})
  (set M.prompt-fragments {:before-body []
                           :before-context []
                           :end []})
  (set M.extensions {})
  (set M.ui-slot nil)
  nil)

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

(fn append-handler [event-name entry]
  (let [bucket (or (. M.handlers event-name) [])]
    (table.insert bucket entry)
    (tset M.handlers event-name bucket)))

(fn remove-handler [event-name entry]
  (let [bucket (. M.handlers event-name)]
    (when bucket
      (remove-where bucket (fn [e _] (= e entry))))))

;; -----------------------------------------------------------------
;; Event bus
;; -----------------------------------------------------------------

(fn dispatch-bucket [bucket ev]
  (when bucket
    (each [_ entry (ipairs bucket)]
      ;; pcall isolation — one bad subscriber does not block siblings.
      ;; Errors are silently swallowed for now; v1.x can add an error
      ;; channel via the bus itself once an extension wants to consume it.
      (pcall entry.fn ev))))

(fn M.emit [ev]
  "Dispatch ev to handlers[ev.type] and the `:*` wildcard bucket. Each
   handler is pcall'd; one error does not block subsequent handlers."
  (when (and ev ev.type)
    (dispatch-bucket (. M.handlers ev.type) ev))
  (dispatch-bucket (. M.handlers :*) ev)
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
    (table.insert M.tools-extra tagged)
    (handle-result :tool spec.name owner
      (fn []
        (remove-where M.tools-extra (fn [t _] (= t tagged)))))))

(fn register-command [spec owner]
  (when (or (not spec) (not spec.name) (not spec.handler))
    (error "register :command requires {:name :handler ...}"))
  (let [name spec.name
        record {:description spec.description
                :handler spec.handler
                :owner owner}]
    (when (. M.commands-extra name)
      ;; Last writer wins, with a (silent) overwrite — main loop emits a
      ;; warning via the bus once an `:extension-loaded` lifecycle event
      ;; exists. For now the loader-less Step 1 just overwrites.
      nil)
    (tset M.commands-extra name record)
    (handle-result :command name owner
      (fn []
        (when (= (?. M.commands-extra name :owner) owner)
          (tset M.commands-extra name nil))))))

(fn register-presenter [spec owner]
  (when (or (not spec) (not spec.name))
    (error "register :presenter requires {:name ...}"))
  (let [tagged (deep-copy spec)]
    (tset tagged :__owner owner)
    (table.insert M.presenters tagged)
    (when (and tagged.active? (not M.ui-slot) tagged.ui)
      (set M.ui-slot tagged.ui))
    (handle-result :presenter spec.name owner
      (fn []
        (remove-where M.presenters (fn [p _] (= p tagged)))
        (when (= M.ui-slot tagged.ui)
          (set M.ui-slot nil)
          ;; Promote the next active presenter, if any.
          (each [_ p (ipairs M.presenters)]
            (when (and (not M.ui-slot) p.active? p.ui)
              (set M.ui-slot p.ui))))))))

(fn register-hook [spec owner]
  (when (or (not spec) (not spec.before-tool))
    (error "register :hook requires {:before-tool fn} (v1 only phase)"))
  (let [entry {:fn spec.before-tool :owner owner}]
    (table.insert M.hooks.before-tool entry)
    (handle-result :hook :before-tool owner
      (fn []
        (remove-where M.hooks.before-tool
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
    (let [bucket (. M.prompt-fragments slot)
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
  (let [bucket (. M.prompt-fragments slot)]
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
  (each [_ entry (ipairs M.hooks.before-tool) &until blocked]
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
    (each [_ t (ipairs M.tools-extra)] (table.insert out t))
    out))

;; -----------------------------------------------------------------
;; Per-owner teardown
;; -----------------------------------------------------------------

(fn M.unregister-by-owner [owner]
  "Drop every registration tagged with `owner`. Used by the (future)
   loader for `/reload-extension`."
  (remove-where M.tools-extra
                (fn [t _] (= t.__owner owner)))
  (each [name rec (pairs M.commands-extra)]
    (when (= rec.owner owner)
      (tset M.commands-extra name nil)))
  (remove-where M.presenters
                (fn [p _] (= p.__owner owner)))
  (when M.ui-slot
    ;; Recompute ui-slot from remaining active presenters.
    (set M.ui-slot nil)
    (each [_ p (ipairs M.presenters)]
      (when (and (not M.ui-slot) p.active? p.ui)
        (set M.ui-slot p.ui))))
  (remove-where M.hooks.before-tool
                (fn [e _] (= e.owner owner)))
  (each [_ slot (ipairs PROMPT-SLOTS)]
    (remove-where (. M.prompt-fragments slot)
                  (fn [e _] (= e.owner owner))))
  (each [event-name bucket (pairs M.handlers)]
    (remove-where bucket (fn [e _] (= e.owner owner))))
  (tset M.extensions owner nil)
  nil)

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
  ;; Each call resolves through M.ui-slot so a presenter that registers
  ;; later in the session takes effect immediately.
  {:has-ui? (fn [] (not= M.ui-slot nil))
   :notify (fn [text opts]
             (if M.ui-slot
                 (M.ui-slot.notify text opts)
                 (fallback-notify text opts)))
   :prompt (fn [opts]
             (if M.ui-slot
                 (M.ui-slot.prompt opts)
                 (fallback-prompt opts)))
   :select (fn [opts]
             (if M.ui-slot
                 (M.ui-slot.select opts)
                 (fallback-select opts)))})

;; -----------------------------------------------------------------
;; Introspection
;; -----------------------------------------------------------------

(fn list-event-handlers []
  (let [out {}]
    (each [event-name bucket (pairs M.handlers)]
      (let [entries []]
        (each [_ e (ipairs bucket)]
          (table.insert entries {:owner e.owner}))
        (tset out event-name entries)))
    out))

(fn list-prompt-contributions []
  (let [out {}]
    (each [_ slot (ipairs PROMPT-SLOTS)]
      (let [bucket (. M.prompt-fragments slot)
            entries []]
        (each [_ e (ipairs bucket)]
          (table.insert entries {:owner e.owner
                                 :dynamic? (= (type e.text-or-fn) :function)}))
        (tset out slot entries)))
    out))

(fn list-tools []
  (let [out []]
    (each [_ t (ipairs M.tools-extra)]
      (table.insert out {:name t.name :owner t.__owner}))
    out))

(fn list-commands []
  (let [out []]
    (each [name rec (pairs M.commands-extra)]
      (table.insert out {:name name :owner rec.owner
                         :description rec.description}))
    out))

(fn list-presenters []
  (let [out []]
    (each [_ p (ipairs M.presenters)]
      (table.insert out {:name p.name :owner p.__owner :active? p.active?}))
    out))

(fn list-extensions []
  (let [out []]
    (each [name rec (pairs M.extensions)]
      (table.insert out {:name name :status rec.status}))
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
  (let [rec (. M.extensions name)]
    (if rec (freeze rec) nil)))

;; -----------------------------------------------------------------
;; Per-extension api factory
;; -----------------------------------------------------------------

(fn M.make-api [owner ?manifest]
  "Return the api table handed to an extension's `register` function.
   `owner` tags every contribution so unregister-by-owner can clean up.
   `?manifest` is captured in M.extensions for introspection."
  (when (and owner ?manifest)
    (tset M.extensions owner
          {:manifest ?manifest :status :loaded :owner owner}))
  {:version M.version
   :register (fn [kind spec] (dispatch-register kind spec owner))
   :on (fn [event-name handler] (M.on event-name handler owner))
   :emit M.emit
   :contribute-system-prompt
     (fn [text-or-fn ?opts]
       (contribute-system-prompt text-or-fn ?opts owner))
   :list M.list
   :describe-extension M.describe-extension
   :ui (build-ui-slot)})

M
