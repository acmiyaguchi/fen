(local harness (require :fen.testing.tui))
(local tb (harness.install-termbox-stub! {:capture? true :cols 80 :rows 10}))
(local api (require :fen.core.extensions.test_api))
(local status (require :fen.extensions.tui.panels.status))

(describe "status semantic dim style"
          (fn []
            (after_each api.reset!)
            (it "keeps muted items readable on the reverse-video bar with a fallback without DIM"
                (fn []
                  (api.reset!)
                  ((. (api.make-runtime-api :probe) :register) :status
                                                               {:name :muted
                                                                :render (fn [_]
                                                                          {:text "~quota"
                                                                           :style :dim})})
                  (local draw (require :fen.extensions.tui.draw))
                  (local original draw.put-clipped)
                  (var observed nil)
                  (set draw.put-clipped
                       (fn [x y fg bg text width]
                         (when (= text "~quota") (set observed fg))
                         (original x y fg bg text width)))
                  (status.paint {:w 80 :status-y 0})
                  (set draw.put-clipped original)
                  (assert.equal (bor tb.WHITE tb.REVERSE tb.DIM) observed)
                  (local dim tb.DIM)
                  (set tb.DIM nil)
                  (set draw.put-clipped
                       (fn [x y fg bg text width]
                         (when (= text "~quota") (set observed fg))
                         (original x y fg bg text width)))
                  (status.paint {:w 80 :status-y 0})
                  (set draw.put-clipped original)
                  (set tb.DIM dim)
                  (assert.equal (bor tb.WHITE tb.REVERSE tb.DIM) observed)
                  (set draw.put-clipped
                       (fn [x y fg bg text width]
                         (when (= text "~quota") (set observed fg))
                         (original x y fg bg text width)))
                  (status.paint {:w 80 :status-y 0})
                  (set draw.put-clipped original)
                  (set tb.DIM nil)
                  (set tb.DIM nil)
                  (set draw.put-clipped
                       (fn [x y fg bg text width]
                         (when (= text "~quota") (set observed fg))
                         (original x y fg bg text width)))
                  (status.paint {:w 80 :status-y 0})
                  (set draw.put-clipped original)
                  (set tb.DIM dim)
                  (assert.equal (bor tb.CYAN tb.REVERSE) observed)))))
