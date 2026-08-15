;; Captured test shim over the loader-owned extension api factory.
;; Extension state is a module singleton, so `make()` resets it; multiple isolated apis per process are unsupported.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))
(local events (require :fen.core.extensions.events))
(local ext-api (require :fen.core.extensions.loader.api))

(local M {})

(fn fresh-captured []
  {:events-out []
   :events-in []
   :tools []
   :commands []
   :presenters []
   :hooks []
   :prompts []
   :introspectors []
   :actions []
   :subscriptions []})

(fn M.reset! []
  "Wipe all registries IN PLACE so identity references survive reset."
  (util.clear-table state.handlers)
  (util.clear-table state.tools-extra)
  (util.clear-table state.commands-extra)
  (util.clear-table state.controls-extra)
  (util.clear-table state.status-extra)
  (util.clear-table state.panel-extra)
  (util.clear-table state.presenters)
  (when (= state.introspectors-extra nil) (set state.introspectors-extra []))
  (util.clear-table state.introspectors-extra)
  (when (= state.actions-extra nil) (set state.actions-extra []))
  (util.clear-table state.actions-extra)
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
  (set state.session.handle nil)
  (util.clear-table state.hooks.before-tool)
  (when (= state.input-handlers nil) (set state.input-handlers []))
  (util.clear-table state.input-handlers)
  (util.clear-table state.prompt-fragments)
  (set state.prompt-next-seq 0)
  (util.clear-table state.extensions)
  (set state.enqueue! nil)
  (set state.runtime-info nil)
  (when (= state.errors nil) (set state.errors []))
  (util.clear-table state.errors)
  (set state.error-log-path nil)
  (when (= state.logs nil) (set state.logs []))
  (util.clear-table state.logs)
  (set state.log-path nil)
  (set state.ui.slot nil)
  nil)

(fn M.make-runtime-api [?owner ?manifest ?opts]
  "Return an uncaptured runtime api for tests that need production-shaped
   registration behavior without requiring the loader-owned factory directly."
  (ext-api.make-api (or ?owner :test)
                    ?manifest
                    (or ?opts {:privileged? true})))

(fn M.make [?owner ?manifest ?opts]
  "Return a captured api. Resets the global extensions registry so the
   test starts from a clean slate."
  (M.reset!)
  (let [owner (or ?owner :test)
        base (M.make-runtime-api owner ?manifest ?opts)
        captured (fresh-captured)
        wrapped {:ui base.ui
                 :list base.list
                 :introspect base.introspect
                 :actions base.actions
                 :settings base.settings
                 :models base.models
                 :log base.log
                 :turn base.turn
                 :enqueue base.enqueue
                 :session base.session
                 :captured captured}]
    (set wrapped.register
         (fn [kind spec]
           (let [result (base.register kind spec)
                 record {:kind kind :spec spec :result result}]
             (if (= kind :tool) (table.insert captured.tools record)
                 (= kind :command) (table.insert captured.commands record)
                 (= kind :presenter) (table.insert captured.presenters record)
                 (= kind :hook) (table.insert captured.hooks record)
                 (= kind :introspect) (table.insert captured.introspectors record)
                 (= kind :action) (table.insert captured.actions record))
             result)))
    (set wrapped.on
         (fn [event-name handler]
           (let [unsub (base.on event-name handler)]
             (table.insert captured.subscriptions
                           {:event event-name :handler handler})
             unsub)))
    (set wrapped.emit
         (fn [ev]
           (table.insert captured.events-out ev)
           (base.emit ev)))
    (set wrapped.prompt
         (fn [text-or-fn opts]
           (let [result (base.prompt text-or-fn opts)]
             (table.insert captured.prompts
                           {:text-or-fn text-or-fn :opts opts :result result})
             result)))
    (set wrapped.fire
         (fn [ev]
           ;; events-in = fired by the test runner; events-out = emitted by the extension.
           (table.insert captured.events-in ev)
           (events.emit ev)))
    wrapped))

M
