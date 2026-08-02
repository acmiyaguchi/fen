(local panel-toggle (require :fen.util.panel_toggle))

(fn fake-api []
  (let [registered []
        listeners {}
        events []
        api {:register (fn [kind spec] (table.insert registered {:kind kind :spec spec}))
             :on (fn [kind handler] (tset listeners kind handler))
             :emit (fn [ev] (table.insert events ev))}]
    {:api api :registered registered :listeners listeners :events events}))

(fn command [fixture]
  (. (. fixture.registered 1) :spec))

(describe "fen.util.panel-toggle"
  (fn []
    (it "installs command, panel, and a mutual-exclusion dismiss handler"
      (fn []
        (let [f (fake-api)
              state {:visible? false :invalidations 0}
              panel-spec {:name :test :height (fn [_] 0) :render (fn [_] [])}]
          (panel-toggle.install! f.api
                                 {:name :test
                                  :command {:name :test :description "Test panel"}
                                  :panel-spec panel-spec
                                  :state state
                                  :on-toggle (fn [] (set state.invalidations (+ state.invalidations 1)))})
          (assert.are.equal :command (. (. f.registered 1) :kind))
          (assert.are.equal :panel (. (. f.registered 2) :kind))
          (assert.is_function (. f.listeners :dismiss))
          ((. (command f) :handler) "" {})
          (assert.is_true state.visible?)
          (assert.are.equal 1 state.invalidations)
          (assert.are.equal :dismiss (. (. f.events 1) :type))
          (assert.are.equal "test panel: on (/test off or /test to hide)"
                            (. (. f.events 2) :text))
          ((. f.listeners :dismiss) {:type :dismiss})
          (assert.is_false state.visible?)
          (assert.are.equal 2 state.invalidations)
          ;; Mutual-exclusion dismissal is silent.
          (assert.are.equal 2 (length f.events)))))

    (it "handles on/off and announces dismissal only when requested"
      (fn []
        (let [f (fake-api) state {:visible? false}
              _ (panel-toggle.install! f.api
                                       {:name :x :command {:name :x}
                                        :panel-spec {:name :x :height (fn [_] 0) :render (fn [_] [])}
                                        :state state})]
          ((. (command f) :handler) "on" {})
          (assert.is_true state.visible?)
          ((. f.listeners :dismiss) {:type :dismiss :announce? true})
          (assert.is_false state.visible?)
          (assert.are.equal "x panel: off" (. (. f.events (length f.events)) :text))
          ((. (command f) :handler) "off" {})
          (assert.is_false state.visible?))))

    (it "composes custom subcommands with the toggle command"
      (fn []
        (let [f (fake-api) state {:visible? false} seen []
              _ (panel-toggle.install! f.api
                                       {:name :mem :command {:name :mem}
                                        :panel-spec {:name :mem :height (fn [_] 0) :render (fn [_] [])}
                                        :state state
                                        :subcommands {:gc {:description "collect"
                                                           :handler (fn [rest run-state]
                                                                      (table.insert seen [rest run-state]))}}})]
          ((. (command f) :handler) "gc full" {:id 7})
          (assert.is_false state.visible?)
          (assert.are.equal "full" (. (. seen 1) 1))
          (assert.are.equal 7 (. (. seen 1) 2 :id))
          ((. (command f) :handler) "on" {})
          (assert.is_true state.visible?))))))
