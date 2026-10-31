;; Regression for #661 (spec/tui-turns, `quitArmOnFocusedTab`):
;; a quit armed on one tab is disarmed when switching tabs by mouse
;; (handle-mouse -> workspaces.activate!), matching the keyboard Alt-arrow behavior.

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub!))
(tui-test.install-markdown-stub!)

(local state (require :fen.extensions.tui.state))
(local workspaces (require :fen.extensions.tui.workspaces))
(local side-chat (require :fen.extensions.tui.side_chat))
(local input (require :fen.extensions.tui.input))
(local tabs (require :fen.extensions.tui.panels.tabs))

(local TAB-ROW 3)

(fn runtime []
  {:opts {:provider :mock :model "m"}
   :agent {:provider-name :mock :model "m" :messages []}
   :make-agent-from-opts (fn [opts on-event _extra]
                           {:provider-name opts.provider
                            :model opts.model
                            :messages []
                            : on-event})})

(fn key! [k ?mod]
  ;; Main is idle throughout.
  (input.handle-key {:key k :ch 0 :mod (or ?mod 0)} nil nil
                    (fn []
                      false)))

(fn click-tab! [id]
  "Click the painted tab for ID through the real tabs layout and handle-mouse."
  (set state.paint-layout
       {:w 80
        :below-status-panels [{:name :tabs :y0 TAB-ROW :y1 TAB-ROW :height 1}]})
  (var x nil)
  (each [_ hit (ipairs (. (tabs.layout 80) :hits))]
    (when (and (= x nil) (= hit.workspace-id id) (= hit.action :activate))
      (set x hit.x0)))
  (assert.is_truthy x)
  (assert.are.same {:workspace-id id :action :activate} (tabs.action-at x 80))
  (input.handle-mouse {:key tb.KEY_MOUSE_LEFT :x x :y TAB-ROW :mod 0}))

(fn setup! []
  "Open btw with a draft, return to main with an empty draft, arm quit there."
  (side-chat.reset!)
  (tui-test.reset-state! {:cols 80 :rows 24})
  (set state.api {:emit (fn [_]) :ui {:select (fn [_] nil)}})
  (workspaces.ensure!)
  (side-chat.open! (runtime) nil)
  (set state.input-buf "side draft")
  (set state.input-cursor (length state.input-buf))
  (workspaces.activate! :main-session)
  (assert.are.equal "" state.input-buf)
  (assert.is_false (key! tb.KEY_CTRL_C))
  (assert.is_true state.pending-quit?))

(describe "mouse switch disarms quit arm (#661)"
          (fn []
            (after_each (fn []
                          (side-chat.reset!)
                          (tui-test.reset-state!)))
            (it "mouse click to btw disarms the quit arm, so Ctrl-C on side draft clears draft instead of quitting"
                (fn []
                  ;; Control: an Alt-right keyboard switch disarms.
                  (setup!)
                  (key! tb.KEY_ARROW_RIGHT tb.MOD_ALT)
                  (assert.are.equal :btw state.active-workspace-id)
                  (assert.is_false state.pending-quit?)
                  (assert.is_false (key! tb.KEY_CTRL_C))
                  (assert.are.equal "" state.input-buf)
                  ;; Fixed: the same switch by mouse now disarms; Ctrl-C clears "side draft" instead of quitting.
                  (setup!)
                  (click-tab! :btw)
                  (let [focused state.active-workspace-id
                        armed? state.pending-quit?
                        quit? (key! tb.KEY_CTRL_C)]
                    (assert.are.equal :btw focused)
                    (assert.is_false armed?)
                    (assert.is_false quit?)
                    (assert.are.equal "" state.input-buf))))))
