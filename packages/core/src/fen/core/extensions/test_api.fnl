;; Test shim for the extension api (issue #15, Step 1).
;;
;; `test-api.make()` returns an api with the same public methods the production
;; `fen.core.extensions.api` factory exposes, plus:
;;
;;   :captured  — table that records every register/contribute/emit/fire call
;;                so tests can assert on what an extension did.
;;   :fire ev   — synchronous event-bus simulation. Records into
;;                captured.events-out and dispatches through events.emit.
;;
;; The parity goal stated in the issue is that `api.list` returns the same
;; shape as production, so introspection doubles as the test affordance.
;;
;; Note: extension state is a module singleton, so `make()` calls
;; `reset!` to start each test from a clean slate. Tests that need multiple
;; isolated apis in the same process are out of scope for v1.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))
(local events (require :fen.core.extensions.events))
(local ext-api (require :fen.core.extensions.api))

(local M {})

(fn fresh-captured []
  {:events-out []
   :events-in []
   :tools []
   :commands []
   :presenters []
   :hooks []
   :prompts []
   :subscriptions []})

;; @doc fen.core.extensions.test_api.reset!
;; kind: function
;; signature: (reset!) -> nil
;; summary: Wipe all extension registries in place for tests without requiring the broad runtime facade.
;; tags: extensions testing reset
(fn M.reset! []
  "Wipe all registries IN PLACE so identity references survive reset."
  (util.clear-table state.handlers)
  (util.clear-table state.tools-extra)
  (util.clear-table state.commands-extra)
  (util.clear-table state.controls-extra)
  (util.clear-table state.status-extra)
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
  (when (= state.errors nil) (set state.errors []))
  (util.clear-table state.errors)
  (set state.error-log-path nil)
  (set state.ui.slot nil)
  nil)

;; @doc fen.core.extensions.test_api.make
;; kind: function
;; signature: (make ?owner ?manifest) -> ExtensionApi
;; summary: Build a captured extension API for tests, resetting global extension state and recording registrations, prompts, and events.
;; tags: extensions testing api
(fn M.make [?owner ?manifest]
  "Return a captured api. Resets the global extensions registry so the
   test starts from a clean slate."
  (M.reset!)
  (let [owner (or ?owner :test)
        base (ext-api.make-api owner ?manifest)
        captured (fresh-captured)
        wrapped {:ui base.ui
                 :list base.list
                 :settings base.settings
                 :models base.models
                 :captured captured}]
    (set wrapped.register
         (fn [kind spec]
           (let [result (base.register kind spec)
                 record {:kind kind :spec spec :result result}]
             (if (= kind :tool) (table.insert captured.tools record)
                 (= kind :command) (table.insert captured.commands record)
                 (= kind :presenter) (table.insert captured.presenters record)
                 (= kind :hook) (table.insert captured.hooks record))
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
           ;; events-in: events fired by the test runner into the bus
           ;; (i.e. simulating events the agent loop would emit). This
           ;; complements events-out (events the extension itself emitted).
           (table.insert captured.events-in ev)
           (events.emit ev)))
    wrapped))

M
