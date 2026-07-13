;; Compact tab bar for presenter workspaces.

(local state (require :fen.extensions.tui.state))
(local tb (require :termbox2))
(local workspaces (require :fen.extensions.tui.workspaces))

(local M {})

(local TC
  {:inactive (bor tb.WHITE tb.DIM)
   ;; Reverse video follows the terminal theme while giving only the selected
   ;; tab a contrasting background.
   :active (bor tb.WHITE tb.REVERSE)
   :separator tb.DEFAULT})

(fn tab-text [ws]
  (let [activity (or ws.activity-count 0)
        unread (if (> activity 0) (.. " +" (tostring activity)) "")]
    (.. " " (or ws.title (tostring ws.id)) unread " ")))

(fn M.height [_ctx]
  ;; Keep the main-session frame byte-for-byte compatible until a second
  ;; workspace exists.
  (if (> (length (workspaces.list)) 1) 1 0))

(fn M.layout [width]
  "Build the visible tab segments and click regions from one geometry model."
  (let [w (math.max 0 (or width state.tb-cols 0))
        segments []
        hits []]
    (var x 0)
    (each [i ws (ipairs (workspaces.list))]
      (when (< x w)
        (when (> i 1)
          (table.insert segments {:text " " :attr TC.separator})
          (set x (+ x 1)))
        (when (< x w)
          (let [text (tab-text ws)
                visible (math.min (length text) (- w x))
                active? (= ws.id state.active-workspace-id)]
            (table.insert segments {:text text
                                    :attr (if active? TC.active TC.inactive)})
            (when (> visible 0)
              (table.insert hits {:x0 x :x1 (+ x visible -1)
                                  :workspace-id ws.id}))
            (set x (+ x (length text)))))))
    {:segments segments :hits hits}))

(fn M.tab-at [x width]
  (var id nil)
  (each [_ hit (ipairs (. (M.layout width) :hits))]
    (when (and (>= x hit.x0) (<= x hit.x1))
      (set id hit.workspace-id)))
  id)

(fn M.render [ctx]
  (let [model (M.layout (math.max 1 (or ctx.w state.tb-cols 1)))]
    [{:segments model.segments}]))

(fn M.spec []
  {:name :tabs :placement :below-status :order 5
   :height M.height :render M.render})

M
