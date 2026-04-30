;; Status bar: top row composed of registered :status items, owned by the
;; TUI presenter. Not a registered :panel — it has its own placement
;; (always y=0) and its own composition rules (Waybar-style left/right
;; sides). Lives in panels/ for symmetry with the other regions.

(local state (require :extensions.tui.state))
(local tb (require :termbox2))
(local extensions (require :core.extensions))
(local draw (require :extensions.tui.draw))

(local M {})

;; Local color presets; mirrors the subset paint.fnl's C uses for status.
(local SC
  {:user      (bor tb.CYAN tb.BOLD)
   :assistant tb.GREEN
   :tool      tb.YELLOW
   :err       (bor tb.RED tb.BOLD)
   :status-fg (bor tb.WHITE tb.REVERSE)
   :status-bg tb.DEFAULT})

(fn status-attr [style]
  (if (= style :error) SC.err
      (= style :user) SC.user
      (= style :assistant) SC.assistant
      (= style :tool) SC.tool
      SC.status-fg))

(fn rendered-status-items [side ctx]
  (let [out []]
    (each [_ item (ipairs (extensions.list :status))]
      (when (= (or item.side :left) side)
        (let [(ok? r) (pcall item.render ctx)]
          (if (and ok? r r.text (not= r.text ""))
              (table.insert out {:text (tostring r.text)
                                 :attr (status-attr r.style)})
              (not ok?)
              (table.insert out {:text (.. "status-error:" (tostring item.name))
                                 :attr SC.err})))))
    out))

(fn status-items-width [items]
  (let [sep-w 2]
    (var n 0)
    (each [i item (ipairs items)]
      (set n (+ n (length item.text)))
      (when (< i (length items))
        (set n (+ n sep-w))))
    n))

(fn put-status-items [x y items width-cap]
  (var cx x)
  (each [i item (ipairs items)]
    (let [remaining (- (+ x width-cap) cx)]
      (when (> remaining 0)
        (draw.put-clipped cx y item.attr SC.status-bg item.text remaining)
        (set cx (+ cx (math.min remaining (length item.text))))))
    (when (< i (length items))
      (let [remaining (- (+ x width-cap) cx)]
        (when (> remaining 0)
          (draw.put-clipped cx y SC.status-fg SC.status-bg "  " remaining)
          (set cx (+ cx (math.min remaining 2))))))))

(fn M.paint [{: w : status-y}]
  (draw.fill-row status-y 0 (- w 1) 32 SC.status-fg SC.status-bg)
  (let [ctx {:w w :status-info state.status-info :state state}
        left-items (rendered-status-items :left ctx)
        right-items (rendered-status-items :right ctx)
        right-w (status-items-width right-items)]
    (put-status-items 1 status-y left-items (math.max 0 (- w 1)))
    (when (> right-w 0)
      (let [x (math.max 0 (- w right-w 1))]
        (put-status-items x status-y right-items (- w x))))))

M
