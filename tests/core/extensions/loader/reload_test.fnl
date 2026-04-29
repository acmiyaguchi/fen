;; Integration test: simulate /reload of core.extensions and assert that
;; bus subscriptions and registrations survive while behavior on the
;; module table picks up the re-required body.
;;
;; Mirrors what manual-reload! in main.fnl does: clear package.loaded for
;; the target, re-require it, then mutate the original module table
;; in place by clearing its keys and copying the new exports across.

(local extensions (require :core.extensions))
(local state (require :core.extensions.state))

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

(describe "core.extensions /reload integration"
  (fn []
    (it "preserves bus subscriptions across a reload"
      (fn []
        (extensions.reset!)
        (let [seen []]
          (extensions.on :* (fn [ev] (table.insert seen ev.type)))
          (manual-reload :core.extensions)
          ;; The subscription was made against state.handlers; after
          ;; reload the same table still holds it.
          (extensions.emit {:type :ping})
          (assert.are.same [:ping] seen))))

    (it "preserves the same module table identity for callers"
      (fn []
        (let [pre extensions]
          (manual-reload :core.extensions)
          (assert.are.equal pre extensions))))

    (it "preserves registered commands"
      (fn []
        (extensions.reset!)
        (let [api (extensions.make-api :live-ext)]
          (api.register :command
                        {:name :survive
                         :handler (fn [_ _] :ok)}))
        (manual-reload :core.extensions)
        (assert.is_not_nil (. state.commands-extra :survive))))

    (it "preserves registered tools"
      (fn []
        (extensions.reset!)
        (let [api (extensions.make-api :live-ext)]
          (api.register :tool {:name :ext-tool :execute (fn [] {})}))
        (manual-reload :core.extensions)
        (let [merged (extensions.merged-tools [])]
          (assert.are.equal 1 (length merged))
          (assert.are.equal :ext-tool (. merged 1 :name)))))

    (it "preserves system-prompt fragments"
      (fn []
        (extensions.reset!)
        (let [api (extensions.make-api :live-ext)]
          (api.prompt "from extension"))
        (manual-reload :core.extensions)
        (assert.are.equal "from extension"
                          (extensions.render-prompt {}))))

    (it "module-table function lookups resolve to the post-reload functions"
      (fn []
        (let [pre-emit extensions.emit]
          (manual-reload :core.extensions)
          ;; After the in-place mutation, the OLD module table's :emit
          ;; field points to the freshly-loaded function, not the
          ;; reference we captured before reload.
          (assert.are_not.equal pre-emit extensions.emit))))

    (it "closures captured into state see the post-reload behavior"
      (fn []
        (extensions.reset!)
        (let [seen []
              ;; This closure mirrors how main.fnl wires the TUI: it
              ;; resolves `extensions.emit` at call time via the captured
              ;; module table, so manual-reload's mutate-in-place lets it
              ;; pick up the new function.
              on-event (fn [ev] (extensions.emit ev))]
          (extensions.on :ping (fn [ev] (table.insert seen ev.type)))
          (manual-reload :core.extensions)
          (on-event {:type :ping})
          (assert.are.same [:ping] seen))))))
