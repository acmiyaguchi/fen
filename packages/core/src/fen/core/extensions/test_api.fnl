;; Test shim for the extension api (issue #15, Step 1).
;;
;; `test-api.make()` returns an api with the same public methods the production
;; `core.extensions` exposes, plus:
;;
;;   :captured  — table that records every register/contribute/emit/fire call
;;                so tests can assert on what an extension did.
;;   :fire ev   — synchronous event-bus simulation. Records into
;;                captured.events-out and dispatches through extensions.emit.
;;
;; The parity goal stated in the issue is that `api.list` returns the same
;; shape as production, so introspection doubles as the test affordance.
;;
;; Note: `extensions` state is a module singleton, so `make()` calls
;; `extensions.reset!` to start each test from a clean slate. Tests that need
;; multiple isolated apis in the same process are out of scope for v1.

(local extensions (require :fen.core.extensions))

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

(fn M.make [?owner ?manifest]
  "Return a captured api. Resets the global extensions registry so the
   test starts from a clean slate."
  (extensions.reset!)
  (let [owner (or ?owner :test)
        base (extensions.make-api owner ?manifest)
        captured (fresh-captured)
        wrapped {:version base.version
                 :ui base.ui
                 :list base.list
                 :complete-once base.complete-once
                 :settings base.settings
                 :models base.models
                 :agent-info base.agent-info
                 :types base.types
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
           (extensions.emit ev)))
    wrapped))

M
