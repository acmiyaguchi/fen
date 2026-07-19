(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local register-registry (require :fen.core.extensions.register))
(local command-registry (require :fen.core.extensions.register.command))
(local tool-registry (require :fen.core.extensions.register.tool))
(local hook-registry (require :fen.core.extensions.register.hook))
(local prompt-registry (require :fen.core.extensions.register.prompt))
(local presenter-registry (require :fen.core.extensions.register.presenter))
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

(fn fresh []
  (extensions.reset!)
  (tset package.loaded :fen.extensions.mem nil)
  (tset package.loaded :fen.extensions.mem.state nil)
  (let [seen []]
    (extensions.on :* (fn [ev] (table.insert seen ev)))
    (let [mem (require :fen.extensions.mem)
          api (ext-api.make-runtime-api :mem)]
      (mem.register api)
      (values seen mem))))

(fn find-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (and (not found) (= ev.type type-key))
      (set found ev)))
  found)

(fn last-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (= ev.type type-key)
      (set found ev)))
  found)

(fn registered? [kind name]
  (var found? false)
  (each [_ rec (ipairs (extensions.list kind))]
    (when (= rec.name name)
      (set found? true)))
  found?)

(describe "extensions.mem"
  (fn []
    (it "registers /mem command and :mem panel"
      (fn []
        (fresh)
        (assert.is_true (registered? :commands :mem))
        (assert.is_true (registered? :panels :mem))))

    (it "/mem toggles panel visibility"
      (fn []
        (let [(seen mem) (fresh)]
          (assert.is_false mem._state.visible?)
          (extensions.dispatch-command "/mem" {})
          (assert.is_true mem._state.visible?)
          (let [ev (last-event seen :info)]
            (assert.is_not_nil ev)
            (assert.is_not_nil (string.find ev.text "mem panel: on" 1 true)))
          (extensions.dispatch-command "/mem" {})
          (assert.is_false mem._state.visible?)
          (let [ev (last-event seen :info)]
            (assert.is_not_nil (string.find ev.text "mem panel: off" 1 true))))))

    (it "/mem on and /mem off are explicit"
      (fn []
        (let [(_ mem) (fresh)]
          (extensions.dispatch-command "/mem off" {})
          (assert.is_false mem._state.visible?)
          (extensions.dispatch-command "/mem on" {})
          (assert.is_true mem._state.visible?)
          (extensions.dispatch-command "/mem on" {})
          (assert.is_true mem._state.visible?))))

    (it "/mem gc emits a one-line GC summary and does not toggle"
      (fn []
        (let [(seen mem) (fresh)]
          (set mem._state.visible? false)
          (extensions.dispatch-command "/mem gc" {})
          (assert.is_false mem._state.visible?)
          (let [ev (last-event seen :info)]
            (assert.is_not_nil ev)
            (assert.is_not_nil (string.find ev.text "mem gc:" 1 true))
            (assert.is_not_nil (string.find ev.text "collected" 1 true))))))

    (it "/mem help lists subcommands without toggling"
      (fn []
        (let [(seen mem) (fresh)]
          (assert.is_false mem._state.visible?)
          (extensions.dispatch-command "/mem help" {})
          (assert.is_false mem._state.visible?)
          (let [ev (last-event seen :info)]
            (assert.is_not_nil ev)
            (assert.is_not_nil (string.find ev.text "/mem" 1 true))
            (assert.is_not_nil (string.find ev.text "gc" 1 true))
            (assert.is_not_nil (string.find ev.text "off" 1 true))))))

    (it "/mem <unknown> emits an error and shows help"
      (fn []
        (let [(seen mem) (fresh)]
          (extensions.dispatch-command "/mem bogus" {})
          (assert.is_false mem._state.visible?)
          (let [err (last-event seen :error)
                info (last-event seen :info)]
            (assert.is_not_nil err)
            (assert.is_not_nil (string.find err.error "unknown subcommand" 1 true))
            (assert.is_not_nil info)
            (assert.is_not_nil (string.find info.text "gc" 1 true))))))

    (it "/mem exposes subcommand argument completions"
      (fn []
        (fresh)
        (let [choices (command-registry.arg-completions :mem "" {})]
          (var saw-gc? false)
          (var saw-help? false)
          (each [_ c (ipairs choices)]
            (when (= c.value "gc") (set saw-gc? true))
            (when (= c.value "help") (set saw-help? true)))
          (assert.is_true saw-gc?)
          (assert.is_true saw-help?))))

    (it "panel height is 0 when hidden and >0 when visible"
      (fn []
        (let [(_ mem) (fresh)
              spec (mem.panel-spec)]
          (set mem._state.visible? false)
          (assert.are.equal 0 (spec.height {:w 80}))
          (set mem._state.visible? true)
          (assert.is_true (> (spec.height {:w 80}) 0)))))

    (it "panel render returns row list when visible, empty when hidden"
      (fn []
        (let [(_ mem) (fresh)
              spec (mem.panel-spec)]
          (set mem._state.visible? false)
          (assert.are.equal 0 (length (spec.render {:w 80})))
          (set mem._state.visible? true)
          (let [rows (spec.render {:w 80})]
            (assert.is_true (> (length rows) 0))
            (var saw-memory? false)
            (var saw-registries? false)
            (each [_ r (ipairs rows)]
              (when (string.find r.text "Memory" 1 true)
                (set saw-memory? true))
              (when (string.find r.text "Registries" 1 true)
                (set saw-registries? true)))
            (assert.is_true saw-memory?)
            (assert.is_true saw-registries?)))))

    (it "panel includes App rows when run-state is cached"
      (fn []
        (let [(_ mem) (fresh)
              spec (mem.panel-spec)]
          (extensions.dispatch-command
            "/mem on"
            {:agent {:messages ["a" "b" "c"]}
             :session {:id "s1" :path "/tmp/s.jsonl"}})
          (let [rows (spec.render {:w 80})]
            (var found-msgs? false)
            (var found-session? false)
            (each [_ r (ipairs rows)]
              (when (string.find r.text "messages: 3" 1 true)
                (set found-msgs? true))
              (when (string.find r.text "session path: /tmp/s.jsonl" 1 true)
                (set found-session? true)))
            (assert.is_true found-msgs?)
            (assert.is_true found-session?)))))

    (it "report-rows returns memory and registry rows"
      (fn []
        (let [(_ mem) (fresh)
              rows (mem.report-rows nil {:gc? false})]
          (var saw-memory? false)
          (var saw-registries? false)
          (var saw-lua-heap? false)
          (each [_ r (ipairs rows)]
            (when (= r.text "Memory") (set saw-memory? true))
            (when (= r.text "Registries") (set saw-registries? true))
            (when (string.find r.text "lua heap:" 1 true)
              (set saw-lua-heap? true)))
          (assert.is_true saw-memory?)
          (assert.is_true saw-registries?)
          (assert.is_true saw-lua-heap?))))

    (it "report-rows with gc? splits before/after heap"
      (fn []
        (let [(_ mem) (fresh)
              rows (mem.report-rows nil {:gc? true})]
          (var saw-before? false)
          (var saw-after? false)
          (var saw-collected? false)
          (each [_ r (ipairs rows)]
            (when (string.find r.text "lua heap before GC" 1 true)
              (set saw-before? true))
            (when (string.find r.text "lua heap after GC" 1 true)
              (set saw-after? true))
            (when (string.find r.text "collected:" 1 true)
              (set saw-collected? true)))
          (assert.is_true saw-before?)
          (assert.is_true saw-after?)
          (assert.is_true saw-collected?))))

    (it ":dismiss closes the panel silently when visible"
      (fn []
        (let [(seen mem) (fresh)]
          (extensions.dispatch-command "/mem on" {})
          (assert.is_true mem._state.visible?)
          (let [info-before (length (icollect [_ ev (ipairs seen)]
                                      (when (= ev.type :info) ev)))]
            (extensions.emit {:type :dismiss})
            (assert.is_false mem._state.visible?)
            ;; Auto-close on :dismiss is silent — no extra :info emitted.
            (let [info-after (length (icollect [_ ev (ipairs seen)]
                                       (when (= ev.type :info) ev)))]
              (assert.are.equal info-before info-after))))))

    (it ":dismiss is a no-op when the panel is hidden"
      (fn []
        (let [(seen mem) (fresh)]
          (assert.is_false mem._state.visible?)
          (let [info-before (length (icollect [_ ev (ipairs seen)]
                                      (when (= ev.type :info) ev)))]
            (extensions.emit {:type :dismiss})
            (assert.is_false mem._state.visible?)
            (let [info-after (length (icollect [_ ev (ipairs seen)]
                                       (when (= ev.type :info) ev)))]
              (assert.are.equal info-before info-after))))))

    (it "samples grow on :llm-end events"
      (fn []
        (let [(_ mem) (fresh)
              before (length mem._state.samples)]
          (extensions.emit {:type :llm-end})
          (extensions.emit {:type :llm-end})
          (assert.are.equal (+ before 2) (length mem._state.samples)))))))
