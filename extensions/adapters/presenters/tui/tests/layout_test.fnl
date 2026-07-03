;; Tests for the placement-walker `paint.layout` and the busy panel.
;; Builds on the same termbox2 + markdown stubs the init_test uses.

(local tui-test (require :fen.testing.tui))
(tui-test.install-termbox-stub!)
(tui-test.install-markdown-stub!)

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
(local state (require :fen.extensions.tui.state))
(local paint (require :fen.extensions.tui.paint))
(local busy-panel (require :fen.extensions.tui.panels.busy))

(fn reset! []
  (extensions.reset!)
  (set state.tb-cols 80)
  (set state.tb-rows 24)
  (set state.input-buf "")
  (set state.input-cursor 0)
  (set state.transcript [])
  (set state.scroll-offset 0)
  (set state.animations? true)
  (set state.status-info
       {:running-label nil :thinking? false :turn-start 0 :spin-frame 0
        :last-input 0 :cum-input 0 :cum-output 0
        :cum-cache-read 0 :cum-cache-write 0
        :steering-queued 0 :follow-up-queued 0
        :cancelling? false}))

(fn register-panel! [api spec]
  (set state.api api)
  (api.register :panel spec))

(describe "paint.layout placement walker"
  (fn []
    (before_each reset!)

    (it "puts status at y=0, input at the bottom, transcript fills the middle when no panels"
      (fn []
        (let [lay (paint.layout)]
          (assert.are.equal 0 lay.status-y)
          (assert.are.equal 1 lay.transcript-y0)
          (assert.are.equal 22 lay.transcript-y1)
          (assert.are.equal 23 lay.input-y0)
          (assert.are.equal 0 (length lay.below-status-panels))
          (assert.are.equal 0 (length lay.above-input-panels)))))

    (it "stacks :above-input panels upward with lower order closer to input"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (register-panel! api {:name :near :placement :above-input :order 10
                                :height (fn [_] 1)
                                :render (fn [_] [{:text "near"}])})
          (register-panel! api {:name :far :placement :above-input :order 20
                                :height (fn [_] 2)
                                :render (fn [_] [{:text "far"}])})
          (let [lay (paint.layout)
                slots lay.above-input-panels
                ;; slots are ordered as built: bottom-up
                near (. slots 1)
                far (. slots 2)]
            (assert.are.equal 2 (length slots))
            (assert.are.equal :near near.name)
            (assert.are.equal 22 near.y0)
            (assert.are.equal 22 near.y1)
            (assert.are.equal :far far.name)
            (assert.are.equal 20 far.y0)
            (assert.are.equal 21 far.y1)
            ;; Transcript shrinks so it does not overlap the panels.
            (assert.are.equal 19 lay.transcript-y1)))))

    (it "stacks :below-status panels downward with lower order closer to status"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (register-panel! api {:name :top :placement :below-status :order 10
                                :height (fn [_] 1)
                                :render (fn [_] [])})
          (register-panel! api {:name :under :placement :below-status :order 20
                                :height (fn [_] 2)
                                :render (fn [_] [])})
          (let [lay (paint.layout)
                slots lay.below-status-panels]
            (assert.are.equal 2 (length slots))
            (assert.are.equal :top (. slots 1 :name))
            (assert.are.equal 1 (. slots 1 :y0))
            (assert.are.equal 1 (. slots 1 :y1))
            (assert.are.equal :under (. slots 2 :name))
            (assert.are.equal 2 (. slots 2 :y0))
            (assert.are.equal 3 (. slots 2 :y1))
            (assert.are.equal 4 lay.transcript-y0)))))

    (it "treats height=0 as hidden (no row consumed)"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (register-panel! api {:name :hidden :placement :above-input :order 10
                                :height (fn [_] 0)
                                :render (fn [_] [])})
          (let [lay (paint.layout)]
            ;; Hidden panels are filtered out before slot allocation.
            (assert.are.equal 0 (length lay.above-input-panels))
            (assert.are.equal 22 lay.transcript-y1)))))

    (it "clips total panel height to the available budget"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          ;; 24 rows, 1 status + 1 input ⇒ 22 rows of budget. Ask for 30.
          (register-panel! api {:name :greedy :placement :above-input :order 10
                                :height (fn [_] 30)
                                :render (fn [_] [])})
          (let [lay (paint.layout)
                slots lay.above-input-panels]
            (assert.are.equal 1 (length slots))
            (assert.are.equal 22 (. slots 1 :height))
            (assert.are.equal 1 (. slots 1 :y0))
            (assert.are.equal 22 (. slots 1 :y1))
            ;; Transcript collapses to zero rows when panels eat the budget.
            (assert.are.equal 0 lay.transcript-h)))))))

(describe "busy panel"
  (fn []
    (before_each reset!)

    (it "reports height 0 when idle"
      (fn []
        (set state.status-info.running-label nil)
        (set state.status-info.thinking? false)
        (assert.are.equal 0 (busy-panel.height {}))
        (assert.are.same [] (busy-panel.render {}))))

    (it "reports height 1 and renders spinner when running-label is set"
      (fn []
        (set state.status-info.running-label "bash")
        (let [rows (busy-panel.render {})]
          (assert.are.equal 1 (busy-panel.height {}))
          (assert.are.equal 1 (length rows))
          (assert.is_truthy (string.match (. rows 1 :text) "bash")))))

    (it "renders thinking when thinking? is true and no running-label"
      (fn []
        (set state.status-info.thinking? true)
        (let [rows (busy-panel.render {})]
          (assert.are.equal 1 (busy-panel.height {}))
          (assert.is_truthy (string.match (. rows 1 :text) "thinking")))))))
