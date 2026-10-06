(local harness (require :fen.testing.tui))
(local tb (harness.install-termbox-stub! {:capture? true :cols 80 :rows 10}))
(local api (require :fen.core.extensions.test_api))
(local module :fen.extensions.tui.panels.status)

(describe "status semantic dim style"
          (fn []
            (var original nil)
            (var old-module nil)
            (var status nil)
            (var observed nil)
            (before_each (fn []
                           (api.reset!)
                           (harness.reset-state! {:cols 80 :rows 10})
                           (set original
                                {:WHITE tb.WHITE
                                 :CYAN tb.CYAN
                                 :REVERSE tb.REVERSE
                                 :DIM tb.DIM
                                 :print tb.print})
                           (set old-module (. package.loaded module))
                           ;; Colors occupy low bits; attributes occupy distinct high bits.
                           (set tb.WHITE 7)
                           (set tb.CYAN 6)
                           (set tb.REVERSE 1024)
                           (set tb.DIM 2048)
                           (tset package.loaded module nil)
                           (set status (require module))
                           (set observed nil)
                           (set tb.print
                                (fn [x y fg bg text]
                                  (when (= text "~quota")
                                    (set observed {:fg fg :bg bg}))
                                  (original.print x y fg bg text)))
                           ((. (api.make-runtime-api :probe) :register) :status
                                                                        {:name :muted
                                                                         :render (fn [_]
                                                                                   {:text "~quota"
                                                                                    :style :dim})})))
            (after_each (fn []
                          (set tb.WHITE original.WHITE)
                          (set tb.CYAN original.CYAN)
                          (set tb.REVERSE original.REVERSE)
                          (set tb.DIM original.DIM)
                          (set tb.print original.print)
                          (tset package.loaded module old-module)
                          (api.reset!)))
            (it "paints stale text dim on the reverse-video status bar"
                (fn []
                  (status.paint {:w 80 :status-y 0})
                  (assert.same {:fg (bor 7 1024 2048) :bg tb.DEFAULT} observed)
                  (assert.equal " ~quota" (. (harness.screen-lines tb) 1))))
            (it "paints stale text cyan on reverse video when DIM is unavailable"
                (fn []
                  (set tb.DIM nil)
                  (status.paint {:w 80 :status-y 0})
                  (assert.same {:fg (bor 6 1024) :bg tb.DEFAULT} observed)
                  (assert.equal " ~quota" (. (harness.screen-lines tb) 1))))))
