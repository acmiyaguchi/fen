;; Integration test: simulate /reload of extension leaf modules and assert that
;; bus subscriptions and registrations survive while behavior on the
;; module tables picks up the re-required bodies.
;;
;; Mirrors what reload-module-in-place! in fen.core.extensions.loader.reload
;; does: clear package.loaded for the target, re-require it, then mutate the
;; original module table in place by clearing its keys and copying the new
;; exports across.

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
   :find-auth-backend auth-backend-registry.find
   :find-session-backend session-backend-registry.find
   :set-active-session-backend! session-backend-registry.set-active!
   :active-session-backend session-backend-registry.active
   :set-session-info! session-backend-registry.set-info!
   :session-info session-backend-registry.info})
(local ext-api (require :fen.core.extensions.test_api))
(local state (require :fen.core.extensions.state))

(fn manual-reload [modname]
  "Mirror of loader.reload's reload-module-in-place! — re-require modname and
   mutate the original module table in place."
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

(local reload-loader (require :fen.core.extensions.loader.reload))

(describe "loader.reload extension modules"
  (fn []
    (local mods [:fen.test.reload-a :fen.test.reload-b :fen.test.reload-c])
    (local original-change-summary reload-loader.change-summary)

    (fn install! []
      (each [_ modname (ipairs mods)]
        (tset package.loaded modname {:generation 0})
        (tset package.preload modname
              (fn [] {:generation 1}))))

    (fn cleanup! []
      (set reload-loader.change-summary original-change-summary)
      (each [_ modname (ipairs mods)]
        (tset package.loaded modname nil)
        (tset package.preload modname nil)))

    (after_each cleanup!)

    (it "keeps every declared module cached when none changed"
      (fn []
        (install!)
        (set reload-loader.change-summary
             (fn [_] {:checked 3 :changed 0 :changed-modules []}))
        (reload-loader.clear-reload-modules! {:reload-modules mods} [])
        (each [_ modname (ipairs mods)]
          (assert.are.equal 0 (. package.loaded modname :generation)))))

    (it "yields after each reloaded module"
      (fn []
        (install!)
        (set reload-loader.change-summary
             (fn [_] {:checked 3 :changed 1
                      :changed-modules [:fen.test.reload-a]}))
        (let [progress []]
          (reload-loader.clear-reload-modules!
            {:reload-modules mods} []
            (fn [item] (table.insert progress item.module)))
          (assert.are.same mods progress))))

    (it "reloads from the first changed module through its consumers"
      (fn []
        (install!)
        (set reload-loader.change-summary
             (fn [_] {:checked 3 :changed 1
                      :changed-modules [:fen.test.reload-b]}))
        (reload-loader.clear-reload-modules! {:reload-modules mods} [])
        (assert.are.equal 0 (. package.loaded :fen.test.reload-a :generation))
        (assert.are.equal 1 (. package.loaded :fen.test.reload-b :generation))
        (assert.are.equal 1 (. package.loaded :fen.test.reload-c :generation))))))

(describe "loader.reload incremental core reload"
  (fn []
    (local modname "fen.zz_incremental_reload_test")
    (local consumer "fen.zz_incremental_reload_consumer_test")
    (local checksum (require :fen.util.checksum))
    (local original-core-modules reload-loader.core-modules)
    (local original-module-fingerprint checksum.module-fingerprint)
    (var source "old")
    (var generation 0)
    (var fail? false)

    (fn install! []
      (set source "old")
      (set generation 0)
      (set fail? false)
      (set state.reload-fingerprints
           {(.. "module:" modname) "old"})
      (set state.reload-core-failures {})
      (set reload-loader.core-modules (fn [] [modname]))
      (set checksum.module-fingerprint
           (fn [name]
             (when (= name modname)
               {:path "fake.fnl" :size (length source) :fingerprint source})))
      (tset package.loaded modname {:generation generation})
      (tset package.preload modname
            (fn []
              (when fail? (error "broken source"))
              (set generation (+ generation 1))
              {:generation generation})))

    (fn cleanup! []
      (set reload-loader.core-modules original-core-modules)
      (set checksum.module-fingerprint original-module-fingerprint)
      (tset package.loaded modname nil)
      (tset package.preload modname nil)
      (tset package.loaded consumer nil)
      (tset package.preload consumer nil)
      (set state.reload-fingerprints {})
      (set state.reload-core-failures {}))

    (before_each install!)
    (after_each cleanup!)

    (it "excludes persistent log sink state from core reloads"
      (fn []
        (var found? false)
        (each [_ name (ipairs (reload-loader.core-modules))]
          (when (= name :fen.util.log_sink) (set found? true)))
        (assert.is_false found?)))

    (it "checks but does not require unchanged modules"
      (fn []
        (let [(n failures summary) (reload-loader.reload-core!)]
          (assert.are.equal 0 n)
          (assert.are.same [] failures)
          (assert.are.equal 1 summary.checked)
          (assert.are.equal 0 summary.changed)
          (assert.are.equal 0 summary.reloaded)
          (assert.are.equal 0 (. package.loaded modname :generation)))))

    (it "yields after every checked core module"
      (fn []
        (set reload-loader.core-modules (fn [] [modname consumer]))
        (tset package.loaded consumer {:generation 0})
        (tset package.preload consumer (fn [] {:generation 1}))
        (let [seen []]
          (reload-loader.reload-core!
            (fn [progress] (table.insert seen progress.module)))
          (assert.are.same [modname consumer] seen))))

    (it "reloads and commits a changed module"
      (fn []
        (set source "new")
        (let [(n failures summary) (reload-loader.reload-core!)]
          (assert.are.equal 1 n)
          (assert.are.same [] failures)
          (assert.are.equal 1 summary.changed)
          (assert.are.equal 1 summary.reloaded)
          (assert.are.equal 1 (. package.loaded modname :generation))
          (assert.are.equal "new" (. state.reload-fingerprints
                                      (.. "module:" modname))))))

    (it "reloads unchanged consumers when one core dependency changes"
      (fn []
        (var consumer-generation 0)
        (set source "new")
        (set reload-loader.core-modules (fn [] [modname consumer]))
        (set checksum.module-fingerprint
             (fn [name]
               (if (= name modname)
                   {:path "dependency.fnl" :size (length source) :fingerprint source}
                   {:path "consumer.fnl" :size 3 :fingerprint "old"})))
        (tset state.reload-fingerprints (.. "module:" consumer) "old")
        (tset package.loaded consumer {:generation 0})
        (tset package.preload consumer
              (fn []
                (set consumer-generation (+ consumer-generation 1))
                {:generation consumer-generation}))
        (let [(_n failures summary) (reload-loader.reload-core!)]
          (assert.are.same [] failures)
          (assert.are.equal 1 summary.changed)
          (assert.are.equal 2 summary.reloaded)
          (assert.are.equal 1 (. package.loaded consumer :generation)))))

    (it "keeps the successful fingerprint after a failed require so retry works"
      (fn []
        (set source "broken")
        (set fail? true)
        (let [(_n failures summary) (reload-loader.reload-core!)]
          (assert.are.equal 1 (length failures))
          (assert.are.equal 1 summary.failed)
          (assert.are.equal "old" (. state.reload-fingerprints
                                      (.. "module:" modname))))
        (set fail? false)
        (let [(n failures summary) (reload-loader.reload-core!)]
          (assert.are.equal 1 n)
          (assert.are.same [] failures)
          (assert.are.equal 1 summary.changed))))

    (it "supports a forced reload of unchanged modules"
      (fn []
        (let [(n failures summary) (reload-loader.reload-core! nil {:force? true})]
          (assert.are.equal 1 n)
          (assert.are.same [] failures)
          (assert.are.equal 0 summary.changed)
          (assert.are.equal 1 summary.reloaded)
          (assert.are.equal 1 (. package.loaded modname :generation)))))

    (it "retries a failed forced reload on the next ordinary reload"
      (fn []
        (set fail? true)
        (let [(_n failures _summary)
              (reload-loader.reload-core! nil {:force? true})]
          (assert.are.equal 1 (length failures)))
        (set fail? false)
        (let [(n failures summary) (reload-loader.reload-core!)]
          (assert.are.equal 1 n)
          (assert.are.same [] failures)
          (assert.are.equal 1 summary.reloaded)
          (assert.are.equal 1 (. package.loaded modname :generation)))))))

(describe "loader.reload core-modules derivation"
  (fn []
    (it "derives loaded fen.* modules, excluding extensions and persistent identity"
      (fn []
        ;; Inject one fake per exclusion class plus one includable fake, so the
        ;; predicate is exercised even in a test process that never loads them.
        (tset package.loaded "fen.main" {})
        (tset package.loaded "fen.extensions.fake_ext" {})
        (tset package.loaded "fen.zz_fake_core" {})
        (let [mods (reload-loader.core-modules)
              has? (fn [name]
                     (var found false)
                     (each [_ m (ipairs mods)]
                       (when (= m name) (set found true)))
                     found)]
          (tset package.loaded "fen.main" nil)
          (tset package.loaded "fen.extensions.fake_ext" nil)
          (tset package.loaded "fen.zz_fake_core" nil)
          ;; genuinely loaded in this test process
          (assert.is_true (has? "fen.core.extensions.events"))
          (assert.is_true (has? "fen.util.checksum"))
          (assert.is_true (has? "fen.zz_fake_core"))
          ;; excluded: persistent identity and extension modules
          (assert.is_false (has? "fen.main"))
          (assert.is_false (has? "fen.core.extensions.state"))
          (assert.is_false (has? "fen.extensions.fake_ext")))))))
