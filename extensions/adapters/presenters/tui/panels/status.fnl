;; Status bar: top row composed of registered :status items, owned by the
;; TUI presenter. Not a registered :panel — it has its own placement
;; (always y=0) and its own composition rules (Waybar-style left/right
;; sides). Lives in panels/ for symmetry with the other regions.

(local state (require :fen.extensions.tui.state))
(local tb (require :termbox2))
(local draw (require :fen.extensions.tui.draw))
;; Paint-path list access goes straight to the registry's raw accessor:
;; the frozen `api.list` proxy exists for extension introspection, and its
;; copy/metatable cost is wasted on a per-frame read-only walk.
(local register (require :fen.core.extensions.register))

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

;; @doc fen.extensions.tui.panels.status.ensure-defaults!
;; kind: function
;; signature: (ensure-defaults!) -> nil
;; summary: Backfill persistent status-info fields, token counters, retry state, queue counts, and running-label migration.
;; tags: tui panel status state reload
(fn M.ensure-defaults! []
  "Backfill status-info fields that may be missing on a live state
   table predating their introduction (e.g. after /reload)."
  (when (= state.status-info nil)
    (set state.status-info
         {:model nil :provider nil :thinking-status nil
          :cum-input 0 :cum-output 0 :cum-cache-read 0 :cum-cache-write 0
          :last-input 0 :approx-context 0
          :context-estimated? true :context-source :estimated
          :steering-queued 0 :follow-up-queued 0
          :start-ms 0 :running-label nil :running-tools nil
          :thinking? false :cancelling? false}))
  (let [s state.status-info]
    (when (= s.thinking-status false) (set s.thinking-status nil))
    (when (= s.cum-input nil)        (set s.cum-input 0))
    (when (= s.cum-output nil)       (set s.cum-output 0))
    (when (= s.cum-cache-read nil)   (set s.cum-cache-read 0))
    (when (= s.cum-cache-write nil)  (set s.cum-cache-write 0))
    (when (= s.last-input nil)       (set s.last-input 0))
    (when (= s.approx-context nil)   (set s.approx-context 0))
    (when (= s.context-estimated? nil) (set s.context-estimated? true))
    (when (= s.context-source nil) (set s.context-source :estimated))
    (when (= s.cancelling? nil)      (set s.cancelling? false))
    (when (= s.steering-queued nil)  (set s.steering-queued 0))
    (when (= s.follow-up-queued nil) (set s.follow-up-queued 0))
    (when (= s.turn-start nil)       (set s.turn-start 0))
    (when (= s.spin-frame nil)       (set s.spin-frame 0))
    ;; Migrate old running-tool key → running-label for live state
    ;; that predates the rename.
    (when (and (= s.running-label nil) (. s :running-tool))
      (set s.running-label (. s :running-tool)))
    (when (= s.running-tools nil)    (set s.running-tools nil))
    (when (= s.running-label nil)    (set s.running-label nil))))

(fn rendered-status-items [side ctx]
  (let [out []
        items (register.list-raw :status)]
    (each [_ item (ipairs items)]
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

;; @doc fen.extensions.tui.panels.status.paint
;; kind: function
;; signature: (paint layout) -> nil
;; summary: Paint the top status row by composing registered left and right status items with error isolation.
;; tags: tui panel status paint registry
(fn M.paint [{: w : status-y}]
  (draw.fill-row status-y 0 (- w 1) 32 SC.status-fg SC.status-bg)
  (let [ctx {:w w :status-info state.status-info :state state}
        left-items (rendered-status-items :left ctx)
        right-items (rendered-status-items :right ctx)
        right-w (status-items-width right-items)
        right-x (math.max 0 (- w right-w 1))
        left-x 1
        ;; Keep one blank cell between the two sides. The right side owns
        ;; its space first; left items clip predictably instead of being
        ;; painted underneath and then overwritten on narrow terminals.
        left-cap (math.max 0 (- right-x left-x 1))]
    (put-status-items left-x status-y left-items left-cap)
    (when (> right-w 0)
      (put-status-items right-x status-y right-items (- w right-x)))))

M
