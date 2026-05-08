;; Integration test: simulate /reload of extension leaf modules and assert that
;; bus subscriptions and registrations survive while behavior on the
;; module tables picks up the re-required bodies.
;;
;; Mirrors what manual-reload! in main.fnl does: clear package.loaded for
;; the target, re-require it, then mutate the original module table
;; in place by clearing its keys and copying the new exports across.

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local register-registry (require :fen.core.extensions.register))
(local command-registry (require :fen.core.extensions.register.command))
(local tool-registry (require :fen.core.extensions.register.tool))
(local hook-registry (require :fen.core.extensions.register.hook))
(local prompt-registry (require :fen.core.extensions.register.prompt))
(local presenter-registry (require :fen.core.extensions.register.presenter))
(local introspect-registry (require :fen.core.extensions.register.introspect))
(local provider-registry (require :fen.core.extensions.register.provider))
(local auth-backend-registry (require :fen.core.extensions.register.auth_backend))
(local session-backend-registry (require :fen.core.extensions.register.session_backend))
(fn handle-result [kind name owner unregister]
  {: kind : name : owner : unregister})
(local extensions
  {:reset! test-api.reset!
   :emit events.emit
   :on events.on
   :register register-registry.register
   :unregister-by-owner register-registry.unregister-by-owner
   :list register-registry.list
   :dispatch-command command-registry.dispatch
   :merged-tools tool-registry.merged
   :run-before-tool hook-registry.run-before-tool
   :prompt (fn [text-or-fn ?opts owner]
             (prompt-registry.contribute text-or-fn ?opts owner handle-result))
   :render-prompt prompt-registry.render
   :active-presenter presenter-registry.active-presenter
   :init-active-presenter presenter-registry.init-active-presenter
   :run-active-presenter presenter-registry.run-active-presenter
   :shutdown-active-presenter presenter-registry.shutdown-active-presenter
   :find-provider provider-registry.find
   :list-providers-by-api provider-registry.list-by-api
   :find-auth-backend auth-backend-registry.find
   :find-session-backend session-backend-registry.find
   :set-active-session-backend! session-backend-registry.set-active!
   :active-session-backend session-backend-registry.active
   :set-session-info! session-backend-registry.set-info!
   :session-info session-backend-registry.info})
(local ext-api (require :fen.core.extensions.test_api))
(local state (require :fen.core.extensions.state))

(fn manual-reload [modname]
  "Mirror of main.fnl's manual-reload! — re-require modname and mutate
   the original module table in place."
  (let [old (. package.loaded modname)]
    (tset package.loaded modname nil)
    (let [new (require modname)]
      (when (and (= (type old) :table) (= (type new) :table))
        (each [k _ (pairs old)] (tset old k nil))
        (each [k v (pairs new)] (tset old k v))
        (tset package.loaded modname old)))))

(describe "core extension leaf-module /reload integration"
  (fn []
    (it "preserves bus subscriptions across a reload"
      (fn []
        (extensions.reset!)
        (let [seen []]
          (extensions.on :* (fn [ev] (table.insert seen ev.type)))
          (manual-reload :fen.core.extensions.events)
          ;; The subscription was made against state.handlers; after
          ;; reload the same table still holds it.
          (extensions.emit {:type :ping})
          (assert.are.same [:ping] seen))))

    (it "preserves the same module table identity for callers"
      (fn []
        (let [pre events]
          (manual-reload :fen.core.extensions.events)
          (assert.are.equal pre events))))

    (it "preserves registered commands"
      (fn []
        (extensions.reset!)
        (let [api (ext-api.make-runtime-api :live-ext)]
          (api.register :command
                        {:name :survive
                         :handler (fn [_ _] :ok)}))
        (manual-reload :fen.core.extensions.register.command)
        (assert.is_not_nil (. state.commands-extra :survive))))

    (it "preserves registered tools"
      (fn []
        (extensions.reset!)
        (let [api (ext-api.make-runtime-api :live-ext)]
          (api.register :tool {:name :ext-tool :execute (fn [] {})}))
        (manual-reload :fen.core.extensions.register.tool)
        (let [merged (tool-registry.merged [])]
          (assert.are.equal 1 (length merged))
          (assert.are.equal :ext-tool (. merged 1 :name)))))

    (it "preserves registered introspectors"
      (fn []
        (extensions.reset!)
        (let [api (ext-api.make-runtime-api :live-ext)]
          (api.register :introspect {:name :state :snapshot (fn [_] {:ok true})}))
        (manual-reload :fen.core.extensions.register.introspect)
        (let [snapshots (introspect-registry.collect)]
          (assert.are.equal true (. snapshots :live-ext :state :ok)))))

    (it "preserves system-prompt fragments"
      (fn []
        (extensions.reset!)
        (let [api (ext-api.make-runtime-api :live-ext)]
          (api.prompt "from extension"))
        (manual-reload :fen.core.extensions.register.prompt)
        (assert.are.equal "from extension"
                          (prompt-registry.render {}))))

    (it "module-table function lookups resolve to the post-reload functions"
      (fn []
        (let [pre-emit events.emit]
          (manual-reload :fen.core.extensions.events)
          ;; After the in-place mutation, the OLD module table's :emit
          ;; field points to the freshly-loaded function, not the
          ;; reference we captured before reload.
          (assert.are_not.equal pre-emit events.emit))))

    (it "closures captured into state see the post-reload behavior"
      (fn []
        (extensions.reset!)
        (let [seen []
              ;; This closure mirrors how main.fnl wires the TUI: it
              ;; resolves `events.emit` at call time via the captured
              ;; module table, so manual-reload's mutate-in-place lets it
              ;; pick up the new function.
              on-event (fn [ev] (events.emit ev))]
          (events.on :ping (fn [ev] (table.insert seen ev.type)))
          (manual-reload :fen.core.extensions.events)
          (on-event {:type :ping})
          (assert.are.same [:ping] seen))))))
